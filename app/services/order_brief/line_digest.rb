# frozen_string_literal: true

module OrderBrief
  # 把前一天的訂單簡報推到有訂閱「order_brief」的 LINE 群組，格式照使用者每天看的那份：
  # 重點（AI）→ 總覽（文字）→ PDRN／全能表格（圖片）→ 其他舊客（文字）→ 很久沒回來表格（圖片）。
  # 匯入已付款訂單（/imports 或 rake import:paid_orders）跑完後呼叫；一天可能匯入好幾次，
  # 同一天的簡報只發一次（line_digest_deliveries 唯一索引），FORCE 才重發。
  # 星期一一次匯入五六日時，三天各發一份（簡報是逐人明細，合併會太長）。
  class LineDigest
    TOPIC = "order_brief"

    def self.after_import
      LineDigestDelivery.pending_days(TOPIC, through: Date.current - 1).sum { |day| call(day) }
    rescue StandardError => e
      Rails.logger.warn("[order_brief] LINE 推播失敗：#{e.class}: #{e.message}")
      0
    end

    def self.call(day, force: false)
      new(day).call(force: force)
    end

    def initialize(day, line: LineBot::Client.new)
      @day = day.to_date
      @line = line
    end

    # 回傳發送的群組數；沒設定 LINE、沒有訂閱群組、當天沒訂單（還沒匯入）、已發過都回 0
    def call(force: false)
      return 0 unless LineBot::Client.configured?

      groups = LineBotGroup.subscribed_to(TOPIC).to_a
      return 0 if groups.empty?

      return 0 unless pushable?

      LineDigestDelivery.deliver_once(TOPIC, @day, force: force) { push(groups) }
    end

    def pushable? = !report.empty?

    # 直接發給這些群組，不看也不記「已發送」（/line_bot_groups 補發單一群組用）；回傳群組數
    def push(groups)
      msgs = messages(report, Highlights.call(report))
      # LINE 一次 push 最多 5 則，超過就分批，群組裡順序不變
      groups.each { |group| msgs.each_slice(LineBot::Client::MAX_MESSAGES) { |batch| @line.push_messages(group.group_id, batch) } }
      groups.size
    end

    # images: false 時表格不畫圖，只放標題（rake order_brief:print 預覽用）
    def messages(report, highlights, images: true)
      list = []
      list.concat(highlight_texts(highlights)) if highlights
      Sections.new(report).parts.each do |kind, *args|
        kind == :text ? list.concat(texts(args.first)) : list << image(*args, upload: images)
      end
      list
    end

    private

    def report = @report ||= Report.new(@day)

    def text(str) = { type: "text", text: str.truncate(LineBot::Client::MAX_TEXT) }

    # 每則都要能在訊息框裡直接看完，太長的切成好幾則
    def texts(str) = LineBot::Client.split_readable(str).map { |part| text(part) }

    # 重點每 3 條一則（使用者要 1–3、4–6、7…，不要一條一則太零散）；標題放在第一則
    HIGHLIGHTS_PER_MESSAGE = 3

    def highlight_texts(highlights)
      highlights.each_slice(HIGHLIGHTS_PER_MESSAGE).with_index.map do |group, i|
        body = Highlights.to_text(@day, group, start: i * HIGHLIGHTS_PER_MESSAGE + 1)
        text(i.zero? ? body : body.split("\n", 3).last)
      end
    end

    # 圖片做不出來（Cloudinary 沒設定或上傳失敗）就改發一行說明，其他段落照發
    def image(name, title, blocks, upload:)
      return text("【#{title}】（表格圖片）") unless upload
      raise "Cloudinary 沒有設定" unless ImageHost.configured?

      ImageHost.upload(TableImage.new(blocks).render, day: @day, name: name)
    rescue StandardError => e
      Rails.logger.warn("[order_brief] 表格圖片失敗：#{e.class}: #{e.message}")
      text("【#{title}】表格圖片產生失敗（#{e.message.truncate(80)}）")
    end
  end
end

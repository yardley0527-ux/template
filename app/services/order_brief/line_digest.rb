# frozen_string_literal: true

module OrderBrief
  # 把前一天的訂單簡報推到有訂閱「order_brief」的 LINE 群組，格式照使用者每天看的那份：
  # 重點（AI）→ 總覽（文字）→ PDRN／全能表格（圖片）→ 其他舊客（文字）→ 很久沒回來表格（圖片）。
  # 匯入已付款訂單（/imports 或 rake import:paid_orders）跑完後呼叫；一天可能匯入好幾次，
  # 同一天的簡報只發一次（line_digest_deliveries 唯一索引），FORCE 才重發。
  class LineDigest
    TOPIC = "order_brief"

    def self.after_import
      call(Date.current - 1)
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

      report = Report.new(@day)
      return 0 if report.empty?

      LineDigestDelivery.deliver_once(TOPIC, @day, force: force) do
        msgs = messages(report, Highlights.call(report))
        # LINE 一次 push 最多 5 則，超過就分批，群組裡順序不變
        groups.each { |group| msgs.each_slice(LineBot::Client::MAX_MESSAGES) { |batch| @line.push_messages(group.group_id, batch) } }
        groups.size
      end
    end

    # images: false 時表格不畫圖，只放標題（rake order_brief:print 預覽用）
    def messages(report, highlights, images: true)
      list = []
      list << text(Highlights.to_text(@day, highlights)) if highlights
      Sections.new(report).parts.each do |kind, *args|
        list << (kind == :text ? text(args.first) : image(*args, upload: images))
      end
      list
    end

    private

    def text(str) = { type: "text", text: str.truncate(LineBot::Client::MAX_TEXT) }

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

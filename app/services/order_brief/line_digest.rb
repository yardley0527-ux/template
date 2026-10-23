# frozen_string_literal: true

module OrderBrief
  # 把前一天的訂單簡報推到有訂閱「order_brief」的 LINE 群組（例如苼莛國際-策略部）。
  # 匯入已付款訂單（/imports 或 rake import:paid_orders）跑完後呼叫；一天可能匯入好幾次，
  # 同一天的簡報只發一次（line_digest_deliveries 唯一索引），FORCE 才重發。
  class LineDigest
    TOPIC = "order_brief"
    MAX_MESSAGES = 5 # LINE push 一次最多 5 則

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
      return 0 unless claim(force)

      texts = messages(report)
      groups.each { |group| @line.push_texts(group.group_id, texts) }
      LineDigestDelivery.where(topic: TOPIC, report_date: @day).update_all(group_count: groups.size, updated_at: Time.current)
      groups.size
    rescue StandardError
      # 沒發出去就把紀錄拿掉，下次匯入還能再發
      LineDigestDelivery.where(topic: TOPIC, report_date: @day).delete_all unless force
      raise
    end

    # 段落依序塞進最多 5 則訊息，每則不超過 LINE 上限；直播日單一段落太長就按行切開
    def messages(report)
      chunks = report.sections.flat_map { |section| split_long(section) }
      out = chunks.each_with_object([]) do |chunk, acc|
        if acc.any? && acc.last.size + chunk.size + 2 <= LineBot::Client::MAX_TEXT
          acc[-1] = "#{acc.last}\n\n#{chunk}"
        else
          acc << chunk
        end
      end
      return out if out.size <= MAX_MESSAGES

      out.first(MAX_MESSAGES - 1) + ["（內容太長，後面省略；完整版可跑 rake order_brief:print）"]
    end

    private

    def split_long(section)
      return [section] if section.size <= LineBot::Client::MAX_TEXT

      section.lines.each_with_object([+""]) do |line, acc|
        acc << +"" if acc.last.size + line.size > LineBot::Client::MAX_TEXT
        acc.last << line
      end.map(&:chomp)
    end

    def claim(force)
      return true if force

      LineDigestDelivery.create!(topic: TOPIC, report_date: @day)
      true
    rescue ActiveRecord::RecordNotUnique
      false
    end
  end
end

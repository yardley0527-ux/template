# frozen_string_literal: true

module OrderBrief
  # 把前一天的訂單簡報（AI 重點＋Flex 總覽卡片＋客人明細表格卡）推到有訂閱「order_brief」的 LINE 群組。
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
        groups.each { |group| @line.push_messages(group.group_id, msgs) }
        groups.size
      end
    end

    # 重點（文字，AI 失敗就省略）→ 總覽卡片 → 客人明細表格卡；LINE 一次最多 5 則
    def messages(report, highlights)
      list = []
      list << { type: "text", text: Highlights.to_text(@day, highlights).truncate(LineBot::Client::MAX_TEXT) } if highlights
      list << FlexMessage.new(report).to_h
      list.concat(DetailCards.new(report).messages)
      list.first(LineBot::Client::MAX_MESSAGES)
    end
  end
end

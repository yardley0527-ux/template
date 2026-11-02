# frozen_string_literal: true

module IgInbox
  # 每天整理一次前一天的 IG 私訊：給老闆的總結，加上「該新增哪些自動回覆／FAQ」的建議。
  # 只送客人訊息內容給 AI，不送 IG 帳號。
  class Digest
    SCHEMA = {
      type: "object",
      properties: {
        overview: { type: "string" },
        suggestions: {
          type: "array",
          items: {
            type: "object",
            properties: { title: { type: "string" }, detail: { type: "string" } },
            required: %w[title detail], additionalProperties: false
          }
        }
      },
      required: %w[overview suggestions], additionalProperties: false
    }.freeze

    def self.call(day, force: false) = new(day).call(force: force)

    def initialize(day)
      @day = day
    end

    def call(force: false)
      digest = IgInboxDigest.find_or_create_by!(day: @day)
      return digest if digest.status == "done" && !force

      messages = IgMessage.where(from_customer: true, sent_at: @day.in_time_zone.all_day).includes(:ig_conversation).order(:sent_at).to_a
      if messages.empty?
        digest.update!(status: "done", overview: "這天沒有客人私訊。", suggestions: [], error_message: nil, generated_at: Time.current)
        return digest
      end

      json = Claude.call(prompt(messages), SCHEMA)
      digest.update!(status: "done", overview: json["overview"].to_s, suggestions: Array(json["suggestions"]).first(5),
                     error_message: nil, generated_at: Time.current)
      digest
    rescue StandardError => e
      Rails.logger.warn("[ig_inbox] #{@day} 每日整理失敗：#{e.class}: #{e.message}")
      digest&.update!(status: "failed", error_message: "#{e.class}: #{e.message}".truncate(500))
      digest
    end

    private

    def prompt(messages)
      by_conversation = messages.group_by(&:ig_conversation)
      data = by_conversation.map do |c, msgs|
        { 對話: c.id, 類別: c.category, 現在還沒回: c.awaiting_reply, 客人訊息: msgs.map { |m| m.text.to_s.truncate(300) } }
      end
      <<~PROMPT
        你是保健食品電商「苼莛國際生技」的客服主管。以下是 #{@day}（台灣日期）客人在 IG 私訊的內容（JSON，每個對話一筆）：
        #{data.to_json}

        目前網站 FAQ 已有的問題（判斷是不是 FAQ 已經有答案、只是自動回覆沒接上）：
        #{Faq.order(:id).limit(300).pluck(:question).to_json}

        請寫：
        1. overview：給老闆看的總結，3–5 句：共幾個客人來私訊、最多在問什麼、有幾個到現在還沒回、有沒有值得注意的狀況
           （例如很多人問同一個商品缺貨、同一個活動規則看不懂、有客訴）。
        2. suggestions：最多 5 條「該新增哪些自動回覆或 FAQ」的建議，title 寫要新增的關鍵字或問題，detail 寫為什麼（幾個人在問、客人原話怎麼問）。
           打招呼、貼圖這種沒內容的訊息不用建議。

        規則：只根據提供的訊息，不要編造；不要寫出客人個資（電話、地址）；用繁體中文，直接講結論，不要用 markdown 符號。
      PROMPT
    end
  end
end

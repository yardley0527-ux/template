# frozen_string_literal: true

module IgInbox
  # 客人有新訊息的對話請 Claude 分類、標敏感問題（懷孕／哺乳、吃藥、疾病、吃了不舒服、客訴退款），
  # 讓老闆先回重要的。只送最近幾則訊息內容，不送 IG 帳號。失敗就下次同步再試。
  class Classifier
    BATCH = 80
    CONTEXT = 6

    SCHEMA = {
      type: "object",
      properties: {
        conversations: {
          type: "array",
          items: {
            type: "object",
            properties: {
              id: { type: "integer" },
              category: { type: "string", enum: IgConversation::CATEGORIES },
              sensitive: { type: "boolean" },
              sensitive_reason: { type: "string" }
            },
            required: %w[id category sensitive sensitive_reason], additionalProperties: false
          }
        }
      },
      required: %w[conversations], additionalProperties: false
    }.freeze

    def self.call = new.call

    def call
      pending = IgConversation.where("last_customer_message_at > ?", IgConversation::HUMAN_AGENT_WINDOW.ago)
                              .where("classified_at IS NULL OR classified_at < last_customer_message_at")
                              .order(last_customer_message_at: :desc).limit(BATCH).to_a
      return 0 if pending.empty?

      json = Claude.call(prompt(pending), SCHEMA)
      by_id = pending.index_by(&:id)
      now = Time.current
      Array(json["conversations"]).count do |c|
        record = by_id[c["id"].to_i]
        next false unless record && IgConversation::CATEGORIES.include?(c["category"])

        record.update!(category: c["category"], sensitive: c["sensitive"] == true,
                       sensitive_reason: c["sensitive"] ? c["sensitive_reason"].presence : nil, classified_at: now)
      end
    rescue StandardError => e
      Rails.logger.warn("[ig_inbox] 分類失敗，下次同步再試：#{e.class}: #{e.message}")
      0
    end

    private

    def prompt(conversations)
      data = conversations.map do |c|
        msgs = c.ig_messages.order(sent_at: :desc).limit(CONTEXT).reverse
        { id: c.id, 對話: msgs.map { |m| "#{m.from_customer ? '客人' : '我們'}：#{m.text.to_s.truncate(300)}" } }
      end
      <<~PROMPT
        你是保健食品電商「苼莛國際生技」的客服主管。以下是客人在 IG 私訊的對話（JSON，id 是對話編號，每段是最近幾則，舊到新）：
        #{data.to_json}

        每個對話依「客人最近在問什麼」分類（category 只能用給定的選項）。
        sensitive＝客人提到懷孕／哺乳、正在吃藥、疾病或治療、吃了身體不舒服、客訴或要退款，這類要老闆或真人優先回；
        sensitive_reason 用 10 字內寫原因，不敏感就給空字串。
      PROMPT
    end
  end
end

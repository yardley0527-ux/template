# frozen_string_literal: true

require "net/http"

module Manychat
  # 每天整理一次 IG 未回覆問題：Claude 把每則訊息分類、標出敏感問題（懷孕、吃藥、疾病、不良反應、客訴），
  # 再寫總結和「該新增哪些自動回覆／FAQ」的建議，給老闆在 /ig_questions 看。
  # 只送訊息內容給 AI，不送客人姓名和 IG 帳號。分類寫回 ig_questions，總結存 ig_question_digests。
  class QuestionDigest
    CLAUDE_API_URL = "https://api.anthropic.com/v1/messages"
    MODEL = "claude-opus-5-5"

    SCHEMA = {
      type: "object",
      properties: {
        questions: {
          type: "array",
          items: {
            type: "object",
            properties: {
              id: { type: "integer" },
              category: { type: "string", enum: IgQuestion::CATEGORIES },
              sensitive: { type: "boolean" },
              sensitive_reason: { type: "string" }
            },
            required: %w[id category sensitive sensitive_reason], additionalProperties: false
          }
        },
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
      required: %w[questions overview suggestions], additionalProperties: false
    }.freeze

    def self.call(day, force: false)
      new(day).call(force: force)
    end

    def initialize(day)
      @day = day
    end

    # 回傳 IgQuestionDigest；同一天已經做過就直接回傳（force: true 重做）
    def call(force: false)
      digest = IgQuestionDigest.find_or_create_by!(day: @day)
      return digest if digest.status == "done" && !force

      questions = IgQuestion.on_day(@day).order(:asked_at).to_a
      if questions.empty?
        digest.update!(status: "done", overview: "這天沒有未回覆的問題。", suggestions: [], error_message: nil, generated_at: Time.current)
        return digest
      end

      api_key = ENV["ANTHROPIC_API_KEY"].to_s.strip
      raise "ANTHROPIC_API_KEY 未設定" if api_key.empty?

      json = JSON.parse(call_claude(prompt(questions), api_key)[/\{.*\}/m].to_s)
      by_id = questions.index_by(&:id)
      Array(json["questions"]).each do |q|
        record = by_id[q["id"].to_i]
        next unless record && IgQuestion::CATEGORIES.include?(q["category"])

        record.update!(category: q["category"], sensitive: q["sensitive"] == true,
                       sensitive_reason: q["sensitive"] ? q["sensitive_reason"].presence : nil)
      end
      digest.update!(status: "done", overview: json["overview"].to_s, suggestions: Array(json["suggestions"]),
                     error_message: nil, generated_at: Time.current)
      digest
    rescue StandardError => e
      Rails.logger.warn("[ig_questions] #{@day} AI 整理失敗：#{e.class}: #{e.message}")
      digest&.update!(status: "failed", error_message: "#{e.class}: #{e.message}".truncate(500))
      digest
    end

    private

    def prompt(questions)
      faqs = Faq.order(:id).limit(300).pluck(:question)
      <<~PROMPT
        你是保健食品電商「苼莛國際生技」的客服主管。以下是 #{@day}（台灣日期）客人在 IG 私訊、但 ManyChat 沒有自動回覆到的訊息（JSON，id 是編號）：
        #{questions.map { |q| { id: q.id, 訊息: q.question.truncate(500) } }.to_json}

        #{"目前網站 FAQ 已有的問題（供判斷是不是 FAQ 已經有答案、只是自動回覆沒接上）：\n#{faqs.to_json}" if faqs.present?}

        請做三件事：
        1. questions：每則訊息都要分類（category 只能用給定的選項）。
           sensitive＝提到懷孕／哺乳、正在吃藥、疾病或治療、吃了身體不舒服、客訴或要退款，這類要真人回、不能交給機器人；
           sensitive_reason 用 10 字內寫原因，不敏感就給空字串。
        2. overview：給老闆看的今日總結，3–5 句：共幾則、最多的是哪幾類、有沒有值得注意的狀況（例如很多人問同一個商品缺貨、同一個活動規則看不懂）。
        3. suggestions：最多 5 條「該新增哪些自動回覆或 FAQ」的建議，title 寫要新增的關鍵字或問題，detail 寫為什麼（幾則在問、客人原話怎麼問）。
           打招呼、貼圖、已讀這種沒內容的訊息不用建議。

        規則：
        - 只根據提供的訊息，不要編造數字或資料裡沒有的狀況。
        - 不要寫出客人可能的個資（電話、地址）。
        - 用繁體中文，直接講結論，不要客套話，不要用 markdown 符號（** # 等）。
      PROMPT
    end

    # 跟 OrderBrief::Highlights 同一套：直接打 Messages API（專案慣例）
    def call_claude(text, api_key)
      uri = URI(CLAUDE_API_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 300

      req = Net::HTTP::Post.new(uri)
      req["x-api-key"] = api_key
      req["anthropic-version"] = "2023-06-01"
      req["anthropic-beta"] = "server-side-fallback-2026-07-01"
      req["content-type"] = "application/json"
      req.body = {
        model: MODEL,
        max_tokens: 32_000,
        fallbacks: "default",
        output_config: { effort: "medium", format: { type: "json_schema", schema: SCHEMA } },
        messages: [{ role: "user", content: text }]
      }.to_json

      response = http.request(req)
      body = JSON.parse(response.body)
      raise "Claude API #{response.code}: #{body.dig('error', 'message')}" unless response.code == "200"
      raise "Claude 拒絕回應（#{body.dig('stop_details', 'category')}）" if body["stop_reason"] == "refusal"
      raise "Claude 輸出被截斷（max_tokens）" if body["stop_reason"] == "max_tokens"

      Array(body["content"]).select { |b| b["type"] == "text" }.map { |b| b["text"] }.join
    end
  end
end

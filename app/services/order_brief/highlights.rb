# frozen_string_literal: true

require "net/http"

module OrderBrief
  # 訂單簡報的「今天的重點」：把當天數字、前 6 天走勢、每位買家的完整購買歷史交給 Claude，
  # 寫 5–7 條給策略部看的觀察。原本是人工寫的，最常見的錯誤是只看上一單就下因果結論，
  # 所以每位客人都附完整歷史，並在 prompt 裡要求先看歷史再寫。
  # AI 失敗時回 nil，簡報照樣發（只是少了重點）。
  class Highlights
    CLAUDE_API_URL = "https://api.anthropic.com/v1/messages"
    MODEL = "claude-opus-5-5"
    TREND_DAYS = 6

    SCHEMA = {
      type: "object",
      properties: {
        highlights: {
          type: "array",
          items: {
            type: "object",
            properties: { title: { type: "string" }, details: { type: "array", items: { type: "string" } } },
            required: %w[title details], additionalProperties: false
          }
        }
      },
      required: %w[highlights], additionalProperties: false
    }.freeze

    def self.call(report)
      new(report).call
    end

    def initialize(report)
      @report = report
    end

    # [{ "title" => ..., "details" => [...] }, ...] 或 nil
    def call
      api_key = ENV["ANTHROPIC_API_KEY"].to_s.strip
      return nil if api_key.empty?

      json = JSON.parse(call_claude(prompt, api_key)[/\{.*\}/m].to_s)
      list = Array(json["highlights"]).select { |h| h.is_a?(Hash) && h["title"].present? }
      list.presence
    rescue StandardError => e
      Rails.logger.warn("[order_brief] AI 重點失敗，照樣發數字：#{e.class}: #{e.message}")
      nil
    end

    # LINE 純文字：1. 標題，底下「・」條列
    def self.to_text(day, highlights)
      lines = ["📝 #{day.month}/#{day.day} 今天的重點"]
      highlights.each_with_index do |h, i|
        lines += ["", "#{i + 1}. #{h['title']}"]
        Array(h["details"]).each { |d| lines << "・#{d}" }
      end
      lines.join("\n")
    end

    def prompt
      <<~PROMPT
        你是保健食品電商「苼莛國際生技」的 CRM 分析幕僚，要替策略部寫每日訂單簡報的「今天的重點」。
        以下是 #{@report.day}（台灣日期）的已付款訂單資料（JSON）：
        #{facts.to_json}

        寫 5–7 條重點，每條：
        - title：一句結論，要有具體數字（人數、瓶數、金額、天數），60 字以內
        - details：0–5 個補充，點名具體客人和數字（例如「莊潔羽 436 天沒來，以前買過 13 次」），每個 60 字以內

        優先寫：
        - 跟前幾天比變化大的（用「前 6 天」的資料比，例如連續幾天超過多少瓶、近一週最低）
        - 主力產品（#{Report::FOCUS.join('、')}）的回購：第幾次買、瓶數升降、隔多久回來
        - 很久沒來（≥#{Report::LONG_GAP} 天）的老客被什麼產品找回來
        - 新客：人數、占營收比例、買什麼進來、大單
        - 卡別結構的異常（例如黑卡、金卡很少）、實付很低（< $1,000 大多是購物金折抵）

        規則（很重要）：
        - 寫任何「客人從 A 產品轉到 B 產品」「X 帶動 Y」「吃完回來」這類因果或模式之前，先看那位客人的完整購買歷史，
          確認符合才寫，並寫出依據（例如「第 2 次消費」「上一單就是 PDRN3」）。只看上一單容易誤判，寧可不寫。
        - 「吃完回來」要用瓶數和間隔判斷：PDRN 每瓶約吃 10–15 天。
        - 只根據提供的資料，不要編造資料裡沒有的數字、原因或客人；不要寫庫存、行銷活動等資料沒提供的事。
        - 用繁體中文，口吻像同事的工作簡報，直接講結論，不要客套話，不要用 markdown 符號（** # 等）。
      PROMPT
    end

    def facts
      {
        "今天總覽" => @report.summary.transform_values { |v| v.is_a?(Float) ? v.round : v },
        "依卡別" => @report.level_stats.map { |l| l.transform_values { |v| v.is_a?(Float) ? v.round : v } },
        "依產品" => @report.product_stats,
        "主力產品分類" => Report::FOCUS.to_h do |s|
          f = @report.focus(s)
          [s, { "回購" => f[:repeat].map { |e| compact(e) }, "舊客第一次買" => f[:first].map { |e| compact(e) },
                "新客" => f[:fresh].map { |e| compact(e) } }]
        end,
        "很久沒回來（≥#{Report::LONG_GAP} 天）" => @report.long_gap.map { |e| compact(e) },
        "前 #{TREND_DAYS} 天走勢" => trend,
        "每位買家的完整購買歷史" => @report.customer_histories
      }
    end

    private

    def compact(entry)
      entry.transform_values { |v| v.is_a?(Date) ? v.iso8601 : (v.is_a?(Float) ? v.round : v) }
    end

    def trend
      (1..TREND_DAYS).map { |i| @report.day - i }.reverse.filter_map do |d|
        r = Report.new(d)
        next if r.empty?

        s = r.summary
        { "日期" => d.iso8601, "人數" => s[:people], "營收" => s[:revenue].round, "新客" => s[:new_people],
          "各產品付費瓶數" => r.product_stats.to_h { |p| [p[:series], p[:paid]] } }
      end
    end

    # 跟 Seo::LineDigest 同一套：直接打 Messages API（專案慣例），
    # fallbacks: "default" — 萬一被安全分類器誤擋，由伺服器自動改用其他模型重跑。
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
        max_tokens: 16_000,
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

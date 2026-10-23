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

    # LINE 純文字，照使用者的格式：「1. 結論」，補充一行一個「- 」
    def self.to_text(day, highlights)
      lines = ["📝 #{day.month}/#{day.day} 今天的重點"]
      highlights.each_with_index do |h, i|
        lines += ["", "#{i + 1}. #{h['title']}"]
        Array(h["details"]).each { |d| lines << "- #{d}" }
      end
      lines.join("\n")
    end

    # 使用者自己寫的 10/22 重點，當寫法範本（只學寫法，不能抄裡面的數字）
    EXAMPLE = <<~TEXT
      1. PDRN 當天 145 瓶，連續第 3 天超過 120 瓶
      （10/20 是 125 瓶、10/21 是 153 瓶）。29 人買，全部是預購。

      2. 6 位回購 PDRN 的都是第 2 次買，而且每個人都買得比上次多。
      其中 4 位第一次是 9/21–9/27 買的小量（1、3、5 瓶），隔了 25–31 天才回來，這次升到 5 瓶或 11 瓶。照每瓶吃 10–15 天算：
      - Claire 1 瓶、劉芸君 3 瓶、Arianna 3 瓶、elodie42 3 瓶，差不多吃完或快吃完了。
      這是第一次看到明顯「吃完回來」的回購，10/15 那時看到的大多是還沒吃完就加買。
      - 謝雅雯（上次 5 瓶）和王靖崴（上次 11 瓶）還沒吃完，屬於加買。

      3. PDRN 把很久沒來的老客找回來了。12 位舊客是第一次買 PDRN，其中 5 位超過 100 天沒消費：
      - Coco 548 天沒來
      - 莊潔羽 436 天沒來，以前買過 13 次
      - Zzoeshen意含 291 天沒來，以前買過 17 次
      - 林芝君 153 天、曾蜜嘎 119 天

      4. 新客 13 人，占營收 26%，其中 11 人是買 PDRN 進來的。
      陳羿君一張單 $30,600（PDRN 10＋5 瓶），李昀潔 $22,450。

      5. PDRN 和全能開始互相帶客（兩位都是第 2 次消費）：
      - 🐣倫倫🐣：10/15 第一次買 PDRN3，這次買全能5
      - 官郁潔：10/20 第一次買全能5，這次買 PDRN 11 瓶（$22,550）

      6. 全能當天只有 51 瓶，是近一週最低（10/20 是 157 瓶）。
      買的 4 位回購客都是很久沒買全能的老客：Emma 531 天沒買、以前買過 4 次全能；廖家嫺、許异嫺、鄭淳如都是 6 月買過 10送2，這次買 12送1 或 5 瓶。

      7. 黑卡只有 1 人，而且只付了 $63（大概是購物金折抵），金卡 0 人。
      營收主要來自白卡和一般會員。
    TEXT

    def prompt
      <<~PROMPT
        你是保健食品電商「苼莛國際生技」的 CRM 分析幕僚，要替策略部寫每日訂單簡報的「今天的重點」。
        以下是 #{@report.day}（台灣日期）的已付款訂單資料（JSON）：
        #{facts.to_json}

        下面是策略部主管自己寫的一份重點（10/22），請照這個寫法寫今天的：
        <範本>
        #{EXAMPLE}
        </範本>

        範本的寫法：
        - 每條先講結論（title），通常一句話，帶一兩個關鍵數字
        - details 是補充：先講「代表什麼」或「怎麼判斷的」，再點名具體客人；
          像範本第 2 條會說「這是第一次看到明顯吃完回來的回購」，要有這種解讀，不要只是把數字列出來
        - 跟前幾天比只挑一兩個最有意義的數字（例如「連續第 3 天超過 120 瓶」「近一週最低」），不要把每天的數字全部列出來
        - 每條 details 最多 4 個；不重要的就不寫，5–7 條就好
        - 只學寫法，範本裡的數字、客人都是 10/22 的，不要抄

        規則（很重要）：
        - 寫任何「客人從 A 產品轉到 B 產品」「X 帶動 Y」「吃完回來」這類因果或模式之前，先看那位客人的完整購買歷史，
          確認符合才寫，並寫出依據（例如「第 2 次消費」「上一單就是 PDRN3」）。只看上一單容易誤判，寧可不寫。
        - 「吃完回來」要用瓶數和間隔判斷：PDRN 每瓶約吃 10–15 天。
        - 只根據提供的資料，不要編造資料裡沒有的數字、原因或客人；不要寫庫存、行銷活動等資料沒提供的事。
        - 不要出現資料裡的英文欄位名稱或程式用語（例如 pre、paid、gift、gap），全部用中文講。
        - 用繁體中文，直接講結論，不要客套話，不要用 markdown 符號（** # 等）。
      PROMPT
    end

    def facts
      {
        "今天總覽" => zh(@report.summary),
        "依卡別" => @report.level_stats.map { |l| zh(l) },
        "依產品" => @report.product_stats.map { |p| zh(p) },
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

    ZH_KEYS = {
      people: "人數", orders: "張單", revenue: "營收", new_people: "新客人數", new_orders: "新客張單",
      new_revenue: "新客營收", new_share: "新客占營收%", old_people: "舊客人數", old_orders: "舊客張單",
      old_revenue: "舊客營收", level: "卡別", amount: "營收", series: "產品", paid: "付費瓶數", gift: "另送瓶數",
      pre: "其中預購瓶數", name: "客人", today: "今天買", last_date: "上次日期", gap: "隔幾天", note: "備註",
      last_items: "上次買什麼", times: "以前買過幾次", same_item_date: "上次買同品項日期", low_amount: "實付很低",
      repurchased: "回購品項", first_time: "第一次買的品項"
    }.freeze

    # 欄位名稱換成中文，AI 才不會把 pre、gap 這種程式用語寫進重點
    def zh(hash)
      hash.to_h { |k, v| [ZH_KEYS.fetch(k, k.to_s), v.is_a?(Date) ? v.iso8601 : (v.is_a?(Float) ? v.round : v)] }
    end

    def compact(entry) = zh(entry)

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

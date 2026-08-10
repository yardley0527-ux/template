# frozen_string_literal: true

require "net/http"

# 針對單一黑金卡客人，把消費軌跡（近期訂單）＋ CRM 手動備註一起送 Claude，
# 產出「要注意什麼」「下一步行銷可以做什麼」，寫回 CustomerProfile 供報表快取顯示。
# 呼叫時機／範圍見 BlackGoldCustomersController：只有「特別注意」的客人自動觸發，
# 其餘由使用者手動點「AI 分析」按鈕。
class BlackGoldCustomerInsightService
  CLAUDE_API_URL = "https://api.anthropic.com/v1/messages"
  MODEL          = "claude-sonnet-4-6"
  HISTORY_LIMIT  = 8 # 送太多筆訂單只會稀釋重點，近 8 筆足夠看出節奏與品項偏好

  ORDER_TOTAL_SQL = <<~SQL.squish.freeze
    CASE
      WHEN MAX(NULLIF(o.total_amount, 0)) IS NOT NULL THEN MAX(NULLIF(o.total_amount, 0))
      ELSE SUM(COALESCE(o.checkout_amount, 0))
    END
  SQL

  def self.call(customer)
    new(customer).call
  end

  def initialize(customer)
    @customer = customer
    @profile  = customer.customer_profile || customer.build_customer_profile
  end

  def call
    history = order_history
    return failure("這位客人沒有已付款訂單紀錄") if history.empty?

    api_key = ENV["ANTHROPIC_API_KEY"].to_s.strip
    return failure("ANTHROPIC_API_KEY 未設定") if api_key.blank?

    raw    = call_claude(build_prompt(history), api_key)
    parsed = parse_response(raw)
    return failure("AI 回應解析失敗：#{raw.to_s.truncate(200)}") if parsed.nil?

    @profile.update!(
      black_gold_ai_watch:          parsed.fetch("watch", []),
      black_gold_ai_next_actions:   parsed.fetch("next_actions", []),
      black_gold_ai_generated_at:   Time.current,
      black_gold_ai_for_order_date: history.last[:date].to_date
    )
    { ok: true, profile: @profile }
  rescue StandardError => e
    Rails.logger.error("[BlackGoldCustomerInsightService] #{e.class}: #{e.message}")
    failure("#{e.class}: #{e.message}")
  end

  private

  def failure(message)
    { ok: false, error: message }
  end

  # 這位客人全部已付款訂單，依日期排序，取最近 HISTORY_LIMIT 筆
  def order_history
    raw = ShoplineOrder.from("shopline_orders o")
      .where("o.email = ?", @customer.email)
      .where("o.payment_status = '已付款'")
      .select(
        "o.order_number AS order_num",
        "MAX(o.order_date) AS ord_date",
        "#{ORDER_TOTAL_SQL} AS order_total",
        "STRING_AGG(DISTINCT o.product_name, '、' ORDER BY o.product_name) AS products_list"
      )
      .group("o.order_number")
      .to_a
      .sort_by(&:ord_date)

    raw.last(HISTORY_LIMIT).map do |o|
      { date: o.ord_date, amount: o.order_total.to_f, products: o.products_list }
    end
  end

  def build_prompt(history)
    trajectory = history.map do |o|
      "#{o[:date].strftime('%Y/%m/%d')}｜NT$#{o[:amount].to_i}｜#{o[:products]}"
    end.join("\n")

    note = @profile.black_gold_note.presence || "（無）"

    <<~PROMPT
      以下是一位保健食品電商的黑金卡（高消費會員）客人的消費軌跡，由舊到新排列，最後一筆是最新一次購買：

      #{trajectory}

      CRM 人員寫的備註：
      #{note}

      請你是熟悉會員經營的電商顧問，根據以上消費軌跡（品項、金額、間隔的變化）與備註，為老闆和 CRM 人員產出：
      1. watch：這位客人有什麼要注意的地方（例如金額趨勢、品項變化、間隔異常、備註裡提到的狀況）
      2. next_actions：接下來具體可以做的行銷或維繫動作（要具體到可執行，不要空泛的「多關心」）

      只輸出 JSON（不要 markdown code fence、不要任何其他文字），格式：
      {"watch": ["...", "..."], "next_actions": ["...", "..."]}

      規則：
      - watch 和 next_actions 各 1-3 條，每條 40 字以內
      - 只根據提供的消費軌跡與備註推論，不要幻想沒寫到的資訊
      - 備註是（無）時，next_actions 不用提「參考備註」
    PROMPT
  end

  def call_claude(prompt, api_key)
    uri  = URI(CLAUDE_API_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.read_timeout = 60

    req = Net::HTTP::Post.new(uri)
    req["x-api-key"]         = api_key
    req["anthropic-version"] = "2023-06-01"
    req["content-type"]      = "application/json"
    req.body = {
      model:      MODEL,
      max_tokens: 1000,
      messages:   [{ role: "user", content: prompt }]
    }.to_json

    response = http.request(req)
    body     = JSON.parse(response.body)
    raise "Claude API #{response.code}: #{body.dig('error', 'message')}" unless response.code == "200"

    body.dig("content", 0, "text").to_s
  end

  def parse_response(text)
    json = text[/\{.*\}/m]
    return nil if json.nil?

    parsed = JSON.parse(json)
    {
      "watch"        => Array(parsed["watch"]).map(&:to_s).reject(&:blank?),
      "next_actions" => Array(parsed["next_actions"]).map(&:to_s).reject(&:blank?)
    }
  rescue JSON::ParserError
    nil
  end
end

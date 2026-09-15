# frozen_string_literal: true

require "net/http"

# 每週經營決策報告：WeeklyMetricsService 算出所有確定的數字，WeeklyStatusClassifier
# 用固定規則算出本週整體狀態（不是AI自由判斷），WeeklyRiskFlagDetector 算出
# 已觸發的風險旗標，三者一起交給 Claude API，只請 AI 做「解讀／歸因假設／
# 優先排序／改善建議／待辦文字化」——AI 不能重算任何確定性數字，也不能自己
# 選一個 status 或發明風險清單以外的風險。
#
# 2026-09-15 大修（PROMPT_VERSION v2）：報告結構改成「老闆決策摘要 → 經營分析
# → 執行方向 → 資料附錄」四段式，取代舊版純條列的 wins/issues/priorities；
# 風險現在帶 severity，不再是空陣列或無差別條列。
#
# 跟 DailyBriefingService 是同一種落地模式：生成後存進 weekly_briefings，
# 頁面只讀已落地資料，不即時呼叫 API。同一週重新產生會更新同一筆 row。
class WeeklyBriefingService
  CLAUDE_API_URL  = "https://api.anthropic.com/v1/messages"
  MODEL           = "claude-opus-4-8"
  PROMPT_VERSION  = "v2"

  def self.call(week_start: Date.current)
    new(week_start).call
  end

  def initialize(week_start)
    @period = WeeklyPeriod.new(week_start)
  end

  def call
    briefing = WeeklyBriefing.for_week(@period.week_start)
    briefing.week_end = @period.week_end

    metrics = WeeklyMetricsService.call(week_start: @period.week_start)
    risk_flags = WeeklyRiskFlagDetector.call(metrics)
    status = WeeklyStatusClassifier.call(metrics, risk_flags)

    api_key = ENV["ANTHROPIC_API_KEY"].to_s.strip
    if api_key.blank?
      briefing.update!(status: "failed", metrics: metrics, meta: { "risk_flags" => risk_flags, "status_classification" => status },
                        error_message: "ANTHROPIC_API_KEY 未設定")
      return briefing
    end

    raw = call_claude(build_prompt(metrics, risk_flags, status), api_key)
    parsed = parse_response(raw)
    parsed["executive_summary"] = status.merge(parsed["executive_summary"] || {})

    ActiveRecord::Base.transaction do
      briefing.update!(
        status:         "success",
        metrics:        metrics,
        ai_report:      parsed.except("todos"),
        error_message:  nil,
        model:          MODEL,
        prompt_version: PROMPT_VERSION,
        generated_at:   Time.current,
        meta:           { "risk_flags" => risk_flags, "status_classification" => status }
      )
      upsert_todos!(briefing, parsed["todos"])
    end

    briefing
  rescue StandardError => e
    Rails.logger.error("[WeeklyBriefingService] #{e.class}: #{e.message}")
    briefing ||= WeeklyBriefing.for_week(@period.week_start)
    briefing.update!(status: "failed", metrics: metrics || briefing.metrics.presence || {},
                      meta: (risk_flags && status) ? { "risk_flags" => risk_flags, "status_classification" => status } : briefing.meta,
                      error_message: "#{e.class}: #{e.message}")
    briefing
  end

  private

  def upsert_todos!(briefing, raw_todos)
    seen_keys = []

    Array(raw_todos).each do |t|
      next unless t.is_a?(Hash) && t["title"].present?

      target_query = t["target_query"].is_a?(Hash) ? t["target_query"] : {}
      dedupe_key = build_dedupe_key(t, target_query)
      seen_keys << dedupe_key

      resolution = WeeklyBriefingTodoTargetResolver.call(target_query)

      todo = briefing.todos.find_or_initialize_by(dedupe_key: dedupe_key)
      todo.title           = t["title"].to_s.truncate(255)
      todo.description     = t["description"]
      todo.priority        = WeeklyBriefingTodo::PRIORITIES.include?(t["priority"]) ? t["priority"] : "medium"
      todo.suggested_role  = t["suggested_role"]
      todo.due_date        = parse_date(t["due_date"])
      todo.data_issue      = t["data_issue"]
      todo.target_segment  = t["target_segment"]
      todo.target_query    = target_query
      todo.target_count    = resolution[:resolved] ? resolution[:count] : nil
      todo.expected_kpi    = t["expected_kpi"]
      todo.status        ||= "pending"
      todo.save!
    end

    briefing.todos.pending.where.not(dedupe_key: seen_keys).destroy_all if seen_keys.any?
  end

  def build_dedupe_key(todo_hash, target_query)
    basis = target_query["type"].present? ? target_query.sort.to_h.to_json : todo_hash["title"].to_s
    Digest::SHA256.hexdigest(basis)[0, 40]
  end

  def parse_date(value)
    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def build_prompt(metrics, risk_flags, status)
    labeled_flags = risk_flags.map do |f|
      f.merge(
        severity_label: WeeklyRiskFlagDetector::SEVERITY_LABELS[f[:severity]],
        category_label: WeeklyRiskFlagDetector::CATEGORY_LABELS[f[:category]],
        label: WeeklyRiskFlagDetector::KEY_LABELS[f[:key]]
      )
    end

    <<~PROMPT
      你是一家保健食品電商公司的營運分析幕僚，正在為老闆與營運主管撰寫「每週經營決策報告」。
      閱讀者必須在5~10分鐘內看懂：本週好不好、營收變動的真正原因、最大風險與機會、今年能不能超越去年、
      接下來該優先拓新/回購/會員維護/直播還是商品經營、本週有哪些事要老闆決策。

      ＝＝ 本週（#{metrics["period"]["week_start"]} ~ #{metrics["period"]["week_end"]}）結構化數據 ＝＝
      程式已經算好所有數字，你不需要、也不可以自己重新計算或推翻裡面任何一個數字：
      #{metrics.to_json}

      ＝＝ 本週整體狀態（用固定規則算出，不是你判斷的）＝＝
      #{status.to_json}

      ＝＝ 已觸發的風險旗標（明確門檻式偵測，不是你判斷）＝＝
      #{labeled_flags.to_json}

      請只輸出 JSON（不要 markdown code fence、不要任何其他文字），格式：
      {
        "executive_summary": {
          "one_liner": "一句話結論，要跟上面的status_label一致",
          "status_basis": "為什麼是這個狀態，具體引用數據",
          "top_findings": [{"finding":"發生什麼","data_evidence":"數據證據","why_it_matters":"為什麼重要","nature":"short_term或structural","revenue_impact":"對未來營收的影響"}]（最多3項）,
          "decisions": [{"question":"決策問題","current_situation":"目前狀況","data_evidence":"數據證據",
            "option_a":{"action":"做法","benefit":"預期效益","risk":"風險","condition":"適用條件"},
            "option_b":{"action":"做法","benefit":"預期效益","risk":"風險","condition":"適用條件"},
            "option_c":null或同上格式,
            "recommended_option":"A或B或C","recommendation_reason":"必須引用CRM數據",
            "impact_if_no_decision":"不決策的影響","next_week_kpi":"下週驗證KPI"}]（最多3項，只放真正需要老闆決策的事，不是一般待辦；必須明確推薦一個方案，不能寫視情況而定）,
          "biggest_risk": {"description":"...","data_evidence":"..."},
          "biggest_opportunity": {"description":"...","data_evidence":"..."}
        },
        "business_analysis": {
          "revenue_and_forecast": ["條列重點，每條先講結論再講數據"],
          "revenue_change_breakdown": ["營收變動主要來自購買人數/客單價/新客/舊客/卡別結構/商品組合中的哪一項，要拆解原因，不能只寫上升或下降"],
          "new_and_returning_customers": ["..."],
          "livestream_performance": ["..."],
          "membership_health": ["..."],
          "product_and_repurchase": ["..."],
          "next_4_week_outlook": ["未來四週風險與機會"]
        },
        "action_items": [{"action":"...","linked_decision":"對應上面哪一項決策或發現","role":"建議負責角色","deadline":"YYYY-MM-DD","kpi":"..."}]（3~5項，只放跟老闆決策直接相關的執行方向）,
        "todos": [{"title":"任務名稱","description":"任務說明","priority":"high|medium|low","suggested_role":"建議負責角色","due_date":"YYYY-MM-DD","data_issue":"對應的數據問題","target_segment":"目標客群文字描述","target_query":{"type":"...","...":"..."},"expected_kpi":"預期KPI"}]
      }

      規則（違反任何一條都要重寫）：
      1. 先講結論，再講數據。
      2. 明確區分「已證實」「合理推測」「資料不足」，每項原因都要標記其中一種。
      3. 不要把相關性寫成因果關係。
      4. 不要因為單週波動就判斷長期趨勢——除非風險旗標清單裡有 consecutive_revenue_decline 或 status 本身是 structural_decline/high_risk。
      5. 不要用「腰斬」「崩跌」等情緒化詞彙，除非數字確實符合腰斬（≥50%下降）等明確定義。
      6. week_type 是直播週還是自然週要納入考量，不要把活動週跟自然週當同條件比較；如果 comparable_basis.basis_note 有值，代表找不到可比較基準，要照實寫「目前只能確認本週低於上週，尚無法判斷是否為基本盤衰退」，不能寫確定性結論。
      7. product_repurchase 裡任何 repurchased_this_week 或 overdue_growth_pct 是 null 的產品，一律寫「資料不足／計算未完成」，絕對不能當作0處理或說「沒有人回購」。
      8. order_quality.funnel_data_note 已經寫好正確的推論邊界，你只能引用它，不能自己延伸出「需求端沒問題」之類的結論。
      9. new_vs_returning.cohort_repurchase 每個 window 如果 sample_sufficient 是 false，要標示「樣本不足」或「早期訊號」，不能直接判斷新客品質變差。
      10. risks 只能對應「已觸發的風險旗標」清單逐一寫，不要發明清單以外的風險；清單是空的代表本週真的沒有已知風險觸發，但如果 top_findings 裡已經指出重大惡化，仍要在 biggest_risk 誠實反映。
      11. membership.near_threshold_note / reconciliation 裡的限制要照實引用，不要自己編門檻數字或假裝加總對得起來。
      12. 每項建議都要引用至少一項數據。
      13. 文字一律用台灣繁體中文，避免「持續觀察」「持續努力」這類空泛用語。
      14. decisions 最多3項，且必須是真正需要老闆拍板的事（例如資源分配、下一場直播定位、要不要調整年度目標），不是行政待辦。
      15. 不要把 CRM 沒有的行銷活動、廣告成本、庫存細節寫成確定事實；campaign_size_note 有值時要照實說明規模不明。
    PROMPT
  end

  def call_claude(prompt, api_key)
    uri  = URI(CLAUDE_API_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.read_timeout = 180

    req = Net::HTTP::Post.new(uri)
    req["x-api-key"]         = api_key
    req["anthropic-version"] = "2023-06-01"
    req["content-type"]      = "application/json"
    req.body = {
      model:      MODEL,
      max_tokens: 8000,
      messages:   [{ role: "user", content: prompt }]
    }.to_json

    response = http.request(req)
    body     = JSON.parse(response.body)
    raise "Claude API #{response.code}: #{body.dig('error', 'message')}" unless response.code == "200"

    body.dig("content", 0, "text").to_s
  end

  def parse_response(text)
    json = text[/\{.*\}/m]
    raise "AI 回應不含 JSON：#{text.truncate(200)}" if json.nil?

    parsed = JSON.parse(json)
    {
      "executive_summary" => parsed["executive_summary"].is_a?(Hash) ? parsed["executive_summary"] : {},
      "business_analysis" => parsed["business_analysis"].is_a?(Hash) ? parsed["business_analysis"] : {},
      "action_items"       => Array(parsed["action_items"]),
      "todos"               => Array(parsed["todos"])
    }
  end
end

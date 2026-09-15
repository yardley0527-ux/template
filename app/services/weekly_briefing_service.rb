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
# 2026-09-15 第二輪修正（PROMPT_VERSION v3）：v2 上線後正文充斥「資料不足／
# 需人工確認／無法判斷」，失去決策價值。改成三級證據制度（A級直接證據／
# B級代理指標／C級無證據），只有C級才不寫進正文；資料缺口改成程式端算好的
# data_gaps 清單，AI 不用也不該重複生成整段警語；decisions 新增
# decision_type（immediate/small_test/needs_more_data），資料不完整時改用
# 小規模測試而不是放棄提出決策。
#
# 2026-09-15 第三輪修正（PROMPT_VERSION v4）：本機用真實 ANTHROPIC_API_KEY
# 實際產生一次報告後，WeeklyBriefingQualityChecker 抓到 v3 舊版規則7仍指示
# AI 對null的回購數字寫「資料不足／計算未完成」，跟同一份prompt別處「全篇
# 禁止這三個字面短語」的規則自相矛盾，導致實測仍有1次「資料不足」殘留。
# 改成要求AI用「比對結果尚未更新完成、此數字暫不採用」等具體描述，不使用
# 被禁字面短語本身。
#
# 跟 DailyBriefingService 是同一種落地模式：生成後存進 weekly_briefings，
# 頁面只讀已落地資料，不即時呼叫 API。同一週重新產生會更新同一筆 row。
class WeeklyBriefingService
  CLAUDE_API_URL  = "https://api.anthropic.com/v1/messages"
  MODEL           = "claude-opus-4-8"
  PROMPT_VERSION  = "v4"

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
      briefing.update!(status: "failed", metrics: metrics,
                        meta: { "risk_flags" => risk_flags, "status_classification" => status, "ai_api_success" => false },
                        error_message: "ANTHROPIC_API_KEY 未設定")
      return briefing
    end

    raw = call_claude(build_prompt(metrics, risk_flags, status), api_key)
    parsed = parse_response(raw)
    parsed["executive_summary"] = status.merge(parsed["executive_summary"] || {})
    ai_report = parsed.except("todos")
    quality_check = WeeklyBriefingQualityChecker.call(ai_report: ai_report, metrics: metrics, risk_flags: risk_flags)

    ActiveRecord::Base.transaction do
      briefing.update!(
        status:         "success",
        metrics:        metrics,
        ai_report:      ai_report,
        error_message:  nil,
        model:          MODEL,
        prompt_version: PROMPT_VERSION,
        generated_at:   Time.current,
        meta:           { "risk_flags" => risk_flags, "status_classification" => status, "quality_check" => quality_check, "ai_api_success" => true }
      )
      upsert_todos!(briefing, parsed["todos"])
    end

    briefing
  rescue StandardError => e
    Rails.logger.error("[WeeklyBriefingService] #{e.class}: #{e.message}")
    briefing ||= WeeklyBriefing.for_week(@period.week_start)
    briefing.update!(status: "failed", metrics: metrics || briefing.metrics.presence || {},
                      meta: (risk_flags && status) ? { "risk_flags" => risk_flags, "status_classification" => status, "ai_api_success" => false } : briefing.meta,
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
    critical_gaps = Array(metrics.dig("data_gaps", "gaps")).select { |g| g["impact"] == "critical" }

    <<~PROMPT
      你的任務是協助經營者在資料不完整的真實商業環境中做決策。缺少部分外部資料時，不可停止分析。
      請先使用CRM直接數據確認現象，再使用多個一致的代理指標提出保守判斷，標示信心程度，並提出風險最低
      且可驗證的行動。只有在沒有任何直接數據或代理指標時，才能判斷為資料不足。不得捏造數字，不得將
      可能原因描述為已證實原因。相同資料缺口整份報告最多提醒一次，完整缺口統一放在附錄（附錄由程式
      自動產生，你不需要、也不要重複寫）。

      你是一家保健食品電商公司的營運分析幕僚，正在為老闆與營運主管撰寫「每週經營決策報告」。
      閱讀者必須在5~10分鐘內看懂：本週好不好、營收變動的真正原因、最大風險與機會、今年能不能超越去年、
      接下來該優先拓新/回購/會員維護/直播還是商品經營、本週有哪些事要老闆決策。

      ＝＝ 三級證據制度（每一句判斷都要落在其中一級，並依規則標示）＝＝
      A級·直接證據：CRM有直接、完整且一致的數據，可用明確語氣下結論（例：「本週新客5人，低於近4週平均17人」）。標示：證據強度：高
      B級·代理指標：CRM沒有完整直接數據，但可用現有數據合理判斷方向，用保守語氣下結論，不得省略判斷
        （例：「沒有廣告投放資料，但新客人數、新客營收同步下降，可判斷新客入口明顯轉弱」）。標示：證據強度：中
      C級·無有效證據：CRM完全沒有直接數據也沒有合理代理指標——這種主題不要寫進正文，直接略過（附錄已經
        由程式列出所有已知缺口，你不需要在正文重複提）。「資料不足」「需人工確認」「無法判斷」這三個字面
        短語，全篇任何地方都不能出現——包括提示critical缺口的時候也一樣，改用具體描述交代情況（例如寫
        「本次比對尚未更新完成，此數字暫不採用」，不要寫「資料不足」；寫「已知XX原因，暫不確認YY」，
        不要寫「無法判斷」）。程式事後會逐字掃描這三個短語，出現就算驗收沒過，請務必換句話說。
      下面這份「本週已知的critical等級資料缺口」（會直接影響核心結論能否成立的缺口，已由程式判定，不是
      你來判斷）如果非空，你可以在對應段落簡短提一次（例如「本週回購比對資料尚未更新完成，此數字暫不
      採用」，不要用「資料不足」這個詞），但只能提
      一次、不要每段重複：
      #{critical_gaps.to_json}
      除了上面這份清單以外，任何 important/supplementary 等級的缺口都不要在正文出現，那些已經自動整理
      到附錄，重複寫只會讓報告看起來充滿警語、失去決策價值。

      ＝＝ 現象與原因要分開講，不要因為原因不明就連現象也不敢下結論 ＝＝
      CRM通常足以確認「現象」（新客下降/營收下降/客單價下降/會員降級增加/商品回購下降/直播成交結果下降），
      但未必能確認「原因」（是否因廣告停投/素材疲乏/流量下降/價格/競品/缺貨/需求改變）。正確寫法範例：
      「本週新客由17人降至5人，新客營收由155,680元降至48,349元，新客入口明顯轉弱（證據強度：高）。CRM
      目前無法進一步區分是流量下降或轉換下降，建議先檢查既有拉新入口，下週追蹤新客人數與新客營收。」
      錯誤寫法：「因為沒有廣告投放資料，所以無法判斷新客下降原因，資料不足。」——這種寫法違反規則，不能出現。

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
          "one_liner": "一句話結論，要跟上面的status_label一致，禁止出現資料不足/無法判斷字樣",
          "status_basis": "為什麼是這個狀態，具體引用數據",
          "top_findings": [{"finding":"發生什麼（標題不能是資料不足）","data_evidence":"數據證據","why_it_matters":"為什麼重要","nature":"short_term或structural","revenue_impact":"對未來營收的影響","confidence":"high或medium"}]（最多3項，只放high/medium信心的發現，low信心的判斷放進business_analysis段落就好，不要放這裡）,
          "decisions": [{"question":"決策問題（標題不能是資料不足）","current_situation":"目前狀況","data_evidence":"數據證據",
            "decision_type":"immediate或small_test或needs_more_data","confidence":"high或medium或low",
            "option_a":{"action":"做法","benefit":"預期效益","risk":"風險","condition":"適用條件"},
            "option_b":{"action":"做法","benefit":"預期效益","risk":"風險","condition":"適用條件"},
            "option_c":null或同上格式,
            "recommended_option":"A或B或C","recommendation_reason":"必須引用CRM數據",
            "test_design": null或{"target":"測試對象","scale":"測試規模","method":"執行方式","success_kpi":"成功KPI","stop_condition":"停止條件","decision_point":"測試後何時再決定是否擴大"}（decision_type是small_test時必填，其他情況給null）,
            "data_needed": null或{"missing_data":"缺少哪個關鍵資料","who_should_provide":"誰該補","when_needed":"何時該補完","decision_once_available":"補完後要決定什麼"}（decision_type是needs_more_data時必填，其他情況給null，這個類型只在錯誤決策風險很高時才用，儘量避免）,
            "impact_if_no_decision":"不決策的影響","next_week_kpi":"下週驗證KPI"}]
            （1~3項，即使資料不完整也一定要提出至少1項，不可以因為資料不足就不給決策；只放真正需要老闆拍板的事，不是行政待辦；decision_type絕大多數應該是immediate或small_test，needs_more_data要盡量少用；recommended_option必須明確指定，不能寫視情況而定）,
          "biggest_risk": {"description":"標題不能是資料不足","data_evidence":"..."},
          "biggest_opportunity": {"description":"標題不能是資料不足","data_evidence":"..."}
        },
        "business_analysis": {
          "revenue_and_forecast": ["條列重點，每條先講結論再講數據，屬於判斷的句子結尾要標註（證據強度：高）或（證據強度：中）"],
          "revenue_change_breakdown": ["營收變動主要來自購買人數/客單價/新客/舊客/卡別結構/商品組合中的哪一項，要拆解原因，不能只寫上升或下降"],
          "new_and_returning_customers": ["..."],
          "livestream_performance": ["只判斷「成交表現」（營收/買家/客單價/組合），不要宣稱能判斷流量或轉換率"],
          "membership_health": ["用升降級紀錄、活躍率、集中度judge會員健康度方向，不要因為沒有官方門檻就不判斷"],
          "product_and_repurchase": ["..."],
          "next_4_week_outlook": ["未來四週風險與機會"]
        },
        "action_items": [{"action":"...","linked_decision":"對應上面哪一項決策或發現","role":"建議負責角色","deadline":"YYYY-MM-DD","kpi":"..."}]（3~5項，只放跟老闆決策直接相關的執行方向）,
        "todos": [{"title":"任務名稱","description":"任務說明","priority":"high|medium|low","suggested_role":"建議負責角色","due_date":"YYYY-MM-DD","data_issue":"對應的數據問題","target_segment":"目標客群文字描述","target_query":{"type":"...","...":"..."},"expected_kpi":"預期KPI"}]
      }

      規則（違反任何一條都要重寫）：
      1. 先講結論，再講數據；結論禁止以「資料不足」開頭。
      2. 每項判斷標記證據強度（高=A級直接證據／中=B級代理指標），C級主題直接不寫，不要在正文交代為什麼不寫。
      3. 不要把相關性寫成因果關係；原因只能寫「可能原因」，不能寫成「已證實原因」。
      4. 不要因為單週波動就判斷長期趨勢——除非風險旗標清單裡有 consecutive_revenue_decline 或 status 本身是 structural_decline/high_risk。
      5. 不要用「腰斬」「崩跌」等情緒化詞彙，除非數字確實符合腰斬（≥50%下降）等明確定義。
      6. week_type 是直播週還是自然週要納入考量，不要把活動週跟自然週當同條件比較；comparable_basis 找不到基準時，改用「本週vs上週」的原始差異做B級代理判斷（仍要下結論，只是信心降為中），不要整句寫成無法判斷。
      7. product_repurchase 裡 repurchased_this_week 或 overdue_growth_pct 是 null 的產品，那個「數字」要說明「比對結果尚未更新完成、此數字暫不採用」（不要用「資料不足」字面），但不影響你對其他有資料的產品或整體舊客回購趨勢下判斷——不要因為某幾個產品的單一數字不可信，就連整個商品段落都放棄判斷。
      8. 付款失敗率低只能判斷「已建立訂單本身沒有付款失敗異常」這個成交結果，不能延伸推論轉換漏斗或需求端正常——但這不代表整段要寫資料不足，正常引用即可，不用每次強調CRM缺什麼。
      9. new_vs_returning.cohort_repurchase 樣本不足時仍要給出「早期訊號，暫定方向」的B級判斷，不要直接跳過不寫。
      10. risks 只能對應「已觸發的風險旗標」清單逐一寫，不要發明清單以外的風險；清單是空的代表本週真的沒有已知風險觸發，但如果 top_findings 裡已經指出重大惡化，仍要在 biggest_risk 誠實反映。
      11. 會員卡別沒有官方升降級門檻不代表不能判斷健康度——用升降級人數/活躍率/集中度做B級判斷。
      12. 每項建議都要引用至少一項數據。
      13. 文字一律用台灣繁體中文，避免「持續觀察」「持續努力」這類空泛用語。
      14. decisions 最少1項、最多3項，資料不完整不是不提決策的理由，改用 small_test 類型降低風險。
      15. 不要把 CRM 沒有的行銷活動、廣告成本、庫存細節寫成確定事實。
      16. 同一個資料缺口全文只能提一次（例如「沒有廣告資料」只在new_and_returning_customers第一次出現時簡短標註，其他段落不要重複）。
      17. 每項decision都要標confidence；low信心不代表不能提決策，改用decision_type="small_test"降低風險，不要因為信心低就不寫。
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

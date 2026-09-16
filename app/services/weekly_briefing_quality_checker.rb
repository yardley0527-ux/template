# frozen_string_literal: true

# 產生報告後的自動品質驗收——純規則檢查，不呼叫AI，跑在WeeklyBriefingService
# 每次成功產生報告之後。檢查結果存進 weekly_briefings.meta["quality_check"]，
# 管理頁直接讀取顯示,不需要人工重新算一次。
#
# 「passed: false」不會擋下報告（報告仍然保存、可以看），只會在畫面上標示
# 「需要檢查」而不是「已完成驗收」，並列出哪幾項沒過，方便重新產生前對照。
class WeeklyBriefingQualityChecker
  BLOCKED_PHRASES = ["資料不足", "無法判斷"].freeze
  REQUIRED_DECISION_FIELDS = %w[
    question data_evidence option_a option_b recommended_option
    recommendation_reason impact_if_no_decision next_week_kpi confidence
  ].freeze
  MAX_UNCLASSIFIED_REVENUE_PCT = 15.0

  # v6新增：AI敘述不能跟程式算好的四大經營燈號矛盾（見 prompt v6 規則19）。
  # 用「有紅/黃燈時AI卻寫安心話術」「沒有任何紅燈時AI卻寫紅燈警語」兩個方向
  # 抓明顯衝突，不做逐句NLP比對——這是防呆，不是要精準抓出每一種措辭矛盾。
  REASSURING_PHRASES = ["表現正常", "一切正常", "數據穩定成長", "無需擔心", "沒有風險", "本週表現良好", "營運穩健"].freeze
  RED_ALERT_PHRASES  = ["紅燈", "需要立即處理", "重大風險", "嚴重惡化"].freeze

  def self.call(ai_report:, metrics:, risk_flags:, business_signals: nil, metric_registry: nil, mandatory_risk_coverage: nil)
    new(ai_report, metrics, risk_flags, business_signals, metric_registry, mandatory_risk_coverage).call
  end

  def initialize(ai_report, metrics, risk_flags, business_signals = nil, metric_registry = nil, mandatory_risk_coverage = nil)
    @report = ai_report || {}
    @metrics = metrics || {}
    @risk_flags = Array(risk_flags)
    @business_signals = Array(business_signals && business_signals["signals"])
    @metric_registry = metric_registry
    @mandatory_risk_coverage = mandatory_risk_coverage
  end

  def call
    content = content_checks
    consistency = consistency_checks
    decisions = decision_checks
    fact_check = ai_fact_check
    mandatory_risk = mandatory_risk_check
    failed_items = content[:failures] + consistency[:failures] + decisions[:failures] + fact_check[:failures] + mandatory_risk[:failures]

    {
      "passed"      => failed_items.empty?,
      "checked_at"  => Time.current,
      "content"     => content[:summary],
      "consistency" => consistency[:summary],
      "decisions"   => decisions[:summary],
      "ai_fact_check" => fact_check[:summary],
      "mandatory_risk_coverage" => mandatory_risk[:summary],
      "failed_items" => failed_items
    }
  end

  private

  # ── 內容驗收 ─────────────────────────────────────────────────
  def content_checks
    text = flattened_text
    insufficient_count = text.scan("資料不足").size
    cannot_judge_count = text.scan("無法判斷").size

    exec_summary = @report["executive_summary"] || {}
    decisions = Array(exec_summary["decisions"])
    findings  = Array(exec_summary["top_findings"])
    action_items = Array(@report["action_items"])

    high_conf   = findings.count { |f| f["confidence"] == "high" }
    medium_conf = findings.count { |f| f["confidence"] == "medium" }
    unlabeled_findings = findings.count { |f| f["confidence"].blank? }
    missing_ab  = decisions.count { |d| d["option_a"].blank? || d["option_b"].blank? }
    unlabeled_decisions = decisions.count { |d| d["confidence"].blank? }
    no_evidence_actions = action_items.count { |a| a["kpi"].blank? && a["linked_decision"].blank? }

    failures = []
    failures << "正文出現「資料不足」#{insufficient_count}次（應為0）" if insufficient_count.positive?
    failures << "正文出現「無法判斷」#{cannot_judge_count}次（應為0）" if cannot_judge_count.positive?
    failures << "老闆決策數量為0" if decisions.empty?
    failures << "老闆決策數量超過3項（#{decisions.size}）" if decisions.size > 3
    failures << "#{unlabeled_findings}項發現未標示信心程度" if unlabeled_findings.positive?
    failures << "#{missing_ab}項決策缺少方案A或方案B" if missing_ab.positive?
    failures << "#{unlabeled_decisions}項決策未標示信心程度" if unlabeled_decisions.positive?
    failures << blocked_headline_failures(exec_summary)

    {
      failures: failures.flatten.compact,
      summary: {
        "insufficient_data_mentions" => insufficient_count,
        "cannot_judge_mentions"      => cannot_judge_count,
        "decision_count"             => decisions.size,
        "high_confidence_findings"   => high_conf,
        "medium_confidence_findings" => medium_conf,
        "findings_missing_confidence" => unlabeled_findings,
        "decisions_missing_ab"        => missing_ab,
        "decisions_missing_confidence" => unlabeled_decisions,
        "action_items_without_evidence" => no_evidence_actions
      }
    }
  end

  # one_liner／發現標題／決策標題／最大風險/機會 這幾個標題型欄位絕對不能出現
  # 「資料不足」「無法判斷」——這是規格明確禁止的位置，跟正文其他地方允許
  # 出現critical等級提示一次不一樣，所以獨立檢查、獨立列出違規欄位名稱。
  def blocked_headline_failures(exec_summary)
    headline_fields = {
      "one_liner" => exec_summary["one_liner"],
      "biggest_risk.description" => exec_summary.dig("biggest_risk", "description"),
      "biggest_opportunity.description" => exec_summary.dig("biggest_opportunity", "description")
    }
    Array(exec_summary["top_findings"]).each_with_index { |f, i| headline_fields["top_findings[#{i}].finding"] = f["finding"] }
    Array(exec_summary["decisions"]).each_with_index { |d, i| headline_fields["decisions[#{i}].question"] = d["question"] }

    headline_fields.filter_map do |field, value|
      next if value.blank?

      hit = BLOCKED_PHRASES.find { |p| value.include?(p) }
      "標題欄位「#{field}」出現禁用字「#{hit}」" if hit
    end
  end

  # ── 資料一致性驗收 ───────────────────────────────────────────
  def consistency_checks
    failures = []
    nvr = @metrics.dig("new_vs_returning", "this_week") || {}
    new_c, ret_c, total_c = nvr.values_at("new_customers", "returning_customers", "total_customers").map(&:to_i)
    failures << "新客(#{new_c})+舊客(#{ret_c}) 不等於 總購買人數(#{total_c})" unless new_c + ret_c == total_c

    new_r, ret_r, total_r = nvr.values_at("new_revenue", "returning_revenue", "total_revenue").map(&:to_f)
    failures << "新客營收+舊客營收(#{(new_r + ret_r).round(2)}) 不等於 總營收(#{total_r})" if (new_r + ret_r - total_r).abs > 1.0

    unclassified_pct = @metrics.dig("membership", "reconciliation", "unclassified_pct").to_f
    failures << "各卡別營收加總與總營收差距達#{unclassified_pct}%（超過#{MAX_UNCLASSIFIED_REVENUE_PCT}%門檻）" if unclassified_pct > MAX_UNCLASSIFIED_REVENUE_PCT

    pr = @metrics["product_repurchase"] || {}
    products = Array(pr["products"])
    returning = pr["returning_customers_this_week"].to_i
    all_zero = products.any? && products.all? { |p| p["repurchased_this_week"] == 0 }
    failures << "偵測到舊客購買人數>0但所有商品回購人數皆為0，卻沒有觸發資料異常防呆" if returning.positive? && all_zero && !pr["contradiction_detected"]

    rp = @metrics["revenue_progress"] || {}
    gap_expected = rp["last_year_full_year_revenue"].to_f - rp["ytd_revenue"].to_f
    failures << "年度營收缺口計算與 去年全年-今年累計 不一致" if (gap_expected - rp["gap_to_beat_last_year"].to_f).abs > 1.0

    days = rp["days_remaining_in_year"].to_i
    weeks = rp["weeks_remaining_in_year"].to_f
    failures << "剩餘週數(#{weeks})與剩餘天數(#{days})換算不一致" if (days / 7.0 - weeks).abs > 0.15

    high_risk_flags = @risk_flags.count { |f| (f[:severity] || f["severity"]) == "high" }
    business_status = @report.dig("executive_summary", "status")
    failures << "有#{high_risk_flags}項高風險旗標，但整體狀態卻是healthy_growth" if high_risk_flags.positive? && business_status == "healthy_growth"

    # 2026-09-15 第五輪修正新增：週期未結束時，本週vs上週的原始差異是「兩天
    # 累計 vs 完整七天」這種不可比較的比較——正式週報不該在這種狀態下產生，
    # 這裡當作驗收失敗項目，逼報告顯示「需要檢查」而不是靜靜放行。
    period_complete = @metrics.dig("period", "complete")
    failures << "統計週期尚未結束（#{@metrics.dig('period', 'week_start')}~#{@metrics.dig('period', 'week_end')}），本週vs上週比較不具參考性" if period_complete == false

    failures << "資料完整度分數尚未產生（data_gaps.completeness_score 缺失）" if @metrics.dig("data_gaps", "completeness_score").nil?

    signal_contradiction = signal_contradiction_failure
    failures << signal_contradiction if signal_contradiction

    {
      failures: failures,
      summary: {
        "period_complete"                   => period_complete,
        "new_plus_returning_equals_total"   => new_c + ret_c == total_c,
        "new_plus_returning_revenue_equals_total" => (new_r + ret_r - total_r).abs <= 1.0,
        "membership_unclassified_pct"       => unclassified_pct,
        "product_repurchase_contradiction_guard_ok" => !(returning.positive? && all_zero && !pr["contradiction_detected"]),
        "revenue_gap_calculation_ok"         => (gap_expected - rp["gap_to_beat_last_year"].to_f).abs <= 1.0,
        "days_weeks_remaining_consistent"    => (days / 7.0 - weeks).abs <= 0.15,
        "risk_vs_status_consistent"          => !(high_risk_flags.positive? && business_status == "healthy_growth"),
        # nil＝沒有business_signals context可比對（例如v5舊報告），不是「已比對過沒問題」；
        # true/false 才代表真的比對過。
        "ai_vs_business_signal_consistent"   => @business_signals.blank? ? nil : signal_contradiction.nil?
      }
    }
  end

  # AI敘述 vs 程式算好的四大經營燈號矛盾偵測（prompt v6 規則19）。不逐句
  # NLP比對，只抓兩個方向的明顯衝突：有紅/黃燈時卻寫安心話術、沒有任何
  # 紅燈時卻寫紅燈警語。@business_signals 沒有值時（例如v5舊報告沒有這段
  # context）視為無法比對，不觸發這項檢查——不能拿v5沒有的資料強行要求v5。
  def signal_contradiction_failure
    return nil if @business_signals.blank?

    text = flattened_text
    has_non_green = @business_signals.any? { |s| %w[red yellow].include?(s["status"]) }
    has_red = @business_signals.any? { |s| s["status"] == "red" }

    if has_non_green
      hit = REASSURING_PHRASES.find { |p| text.include?(p) }
      return "AI敘述出現安心話術「#{hit}」，但程式算出的四大經營燈號已有紅/黃燈，內容矛盾" if hit
    end

    unless has_red
      hit = RED_ALERT_PHRASES.find { |p| text.include?(p) }
      return "AI敘述出現紅燈警語「#{hit}」，但程式算出的四大經營燈號沒有任何紅燈，內容矛盾" if hit
    end

    nil
  end

  # ── 決策品質驗收 ─────────────────────────────────────────────
  def decision_checks
    decisions = Array(@report.dig("executive_summary", "decisions"))
    incomplete = decisions.select { |d| REQUIRED_DECISION_FIELDS.any? { |f| d[f].blank? } }

    failures = incomplete.map do |d|
      missing = REQUIRED_DECISION_FIELDS.select { |f| d[f].blank? }
      "決策「#{d['question'] || '（未命名）'}」缺少：#{missing.join('、')}"
    end

    { failures: failures, summary: { "total" => decisions.size, "incomplete" => incomplete.size } }
  end

  # ── AI數字幻覺防護（見 weekly_ai_fact_validator.rb）─────────────
  # metric_registry 沒有傳入時（例如v5舊呼叫路徑、或未來某處還沒接上）視為
  # 無法比對，不觸發也不算失敗——不能拿沒有registry context的呼叫者強行
  # 要求這項檢查，等同上面business_signals矛盾檢查的處理方式。
  def ai_fact_check
    return { failures: [], summary: nil } if @metric_registry.blank?

    result = WeeklyAiFactValidator.call(ai_report: @report, registry: @metric_registry)
    failures = result["issues"].map do |issue|
      "AI事實查核：欄位「#{issue['field']}」#{issue['message']}"
    end

    { failures: failures, summary: result }
  end

  # 「一、最大風險不能只依賴Prompt」——weekly_briefing_service.rb在存檔前已經
  # 對mandatory topics做過重試＋（必要時）程式覆寫，這裡只負責把最終結果
  # 記錄進品質驗收：如果重試後仍然需要覆寫，代表AI原始輸出真的漏了重點，
  # 即使畫面上最終顯示的biggest_risk已經是程式版本、老闆看到的內容是對的，
  # 品質驗收仍要誠實標「需要檢查」，讓人知道AI這次的表現需要留意。
  def mandatory_risk_check
    return { failures: [], summary: nil } if @mandatory_risk_coverage.blank?

    failures = []
    if @mandatory_risk_coverage["fallback_applied"]
      topics = Array(@mandatory_risk_coverage.dig("uncovered_topics")).map { |t| t["label"] }.join("、")
      failures << "最大風險保底：AI兩次回應皆未點名最高優先級風險主題（#{topics}），已改用程式生成版本覆寫biggest_risk"
    end

    { failures: failures, summary: @mandatory_risk_coverage }
  end

  def flattened_text
    acc = []
    collect_strings(@report, acc)
    acc.join("\n")
  end

  def collect_strings(obj, acc)
    case obj
    when String then acc << obj
    when Array then obj.each { |v| collect_strings(v, acc) }
    when Hash then obj.each_value { |v| collect_strings(v, acc) }
    end
  end
end

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

  def self.call(ai_report:, metrics:, risk_flags:)
    new(ai_report, metrics, risk_flags).call
  end

  def initialize(ai_report, metrics, risk_flags)
    @report = ai_report || {}
    @metrics = metrics || {}
    @risk_flags = Array(risk_flags)
  end

  def call
    content = content_checks
    consistency = consistency_checks
    decisions = decision_checks
    failed_items = content[:failures] + consistency[:failures] + decisions[:failures]

    {
      "passed"      => failed_items.empty?,
      "checked_at"  => Time.current,
      "content"     => content[:summary],
      "consistency" => consistency[:summary],
      "decisions"   => decisions[:summary],
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

    {
      failures: failures,
      summary: {
        "new_plus_returning_equals_total"   => new_c + ret_c == total_c,
        "new_plus_returning_revenue_equals_total" => (new_r + ret_r - total_r).abs <= 1.0,
        "membership_unclassified_pct"       => unclassified_pct,
        "product_repurchase_contradiction_guard_ok" => !(returning.positive? && all_zero && !pr["contradiction_detected"]),
        "revenue_gap_calculation_ok"         => (gap_expected - rp["gap_to_beat_last_year"].to_f).abs <= 1.0,
        "days_weeks_remaining_consistent"    => (days / 7.0 - weeks).abs <= 0.15,
        "risk_vs_status_consistent"          => !(high_risk_flags.positive? && business_status == "healthy_growth")
      }
    }
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

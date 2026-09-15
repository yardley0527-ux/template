# frozen_string_literal: true

require "test_helper"

class WeeklyBriefingQualityCheckerTest < ActiveSupport::TestCase
  def good_decision(overrides = {})
    {
      "question" => "q", "current_situation" => "s", "data_evidence" => "d",
      "option_a" => { "action" => "a" }, "option_b" => { "action" => "b" },
      "recommended_option" => "A", "recommendation_reason" => "r",
      "impact_if_no_decision" => "i", "next_week_kpi" => "k", "confidence" => "high"
    }.merge(overrides)
  end

  def good_report(decisions: [good_decision])
    {
      "executive_summary" => {
        "status" => "flat", "one_liner" => "一句話結論",
        "top_findings" => [{ "finding" => "f", "confidence" => "high" }],
        "decisions" => decisions,
        "biggest_risk" => { "description" => "risk" }, "biggest_opportunity" => { "description" => "opp" }
      },
      "business_analysis" => { "revenue_and_forecast" => ["bullet"] },
      "action_items" => [{ "action" => "a", "kpi" => "k" }]
    }
  end

  def good_metrics
    {
      "period" => { "complete" => true, "week_start" => "2026-06-15", "week_end" => "2026-06-21" },
      "data_gaps" => { "completeness_score" => 46.15 },
      "new_vs_returning" => { "this_week" => { "new_customers" => 5, "returning_customers" => 10, "total_customers" => 15,
                                                 "new_revenue" => 100.0, "returning_revenue" => 200.0, "total_revenue" => 300.0 } },
      "membership" => { "reconciliation" => { "unclassified_pct" => 2.0 } },
      "product_repurchase" => { "products" => [{ "repurchased_this_week" => 3 }], "returning_customers_this_week" => 10, "contradiction_detected" => false },
      "revenue_progress" => { "last_year_full_year_revenue" => 1000.0, "ytd_revenue" => 400.0, "gap_to_beat_last_year" => 600.0,
                               "days_remaining_in_year" => 70, "weeks_remaining_in_year" => 10.0 }
    }
  end

  test "a well-formed report passes with no failed items" do
    result = WeeklyBriefingQualityChecker.call(ai_report: good_report, metrics: good_metrics, risk_flags: [])
    assert result["passed"], result["failed_items"].inspect
    assert_empty result["failed_items"]
  end

  test "counts occurrences of blocked phrases anywhere in the report" do
    report = good_report
    report["business_analysis"]["revenue_and_forecast"] = ["本週資料不足，無法判斷原因"]

    result = WeeklyBriefingQualityChecker.call(ai_report: report, metrics: good_metrics, risk_flags: [])

    assert_not result["passed"]
    assert_equal 1, result["content"]["insufficient_data_mentions"]
    assert_equal 1, result["content"]["cannot_judge_mentions"]
  end

  test "flags a blocked phrase specifically when it appears in a headline field" do
    report = good_report
    report["executive_summary"]["one_liner"] = "本週資料不足"

    result = WeeklyBriefingQualityChecker.call(ai_report: report, metrics: good_metrics, risk_flags: [])

    assert_not result["passed"]
    assert result["failed_items"].any? { |f| f.include?("one_liner") }
  end

  test "fails when there are zero decisions" do
    result = WeeklyBriefingQualityChecker.call(ai_report: good_report(decisions: []), metrics: good_metrics, risk_flags: [])
    assert_not result["passed"]
    assert_includes result["failed_items"], "老闆決策數量為0"
  end

  test "fails when there are more than 3 decisions" do
    result = WeeklyBriefingQualityChecker.call(ai_report: good_report(decisions: Array.new(4) { good_decision }), metrics: good_metrics, risk_flags: [])
    assert_not result["passed"]
    assert result["failed_items"].any? { |f| f.include?("超過3項") }
  end

  test "flags a decision missing option_b or confidence" do
    result = WeeklyBriefingQualityChecker.call(ai_report: good_report(decisions: [good_decision("option_b" => nil, "confidence" => nil)]),
                                                metrics: good_metrics, risk_flags: [])
    assert_not result["passed"]
    assert result["failed_items"].any? { |f| f.include?("方案A或方案B") }
    assert result["failed_items"].any? { |f| f.include?("信心程度") }
  end

  test "fails the consistency check when new+returning customers do not equal total" do
    metrics = good_metrics
    metrics["new_vs_returning"]["this_week"]["total_customers"] = 99

    result = WeeklyBriefingQualityChecker.call(ai_report: good_report, metrics: metrics, risk_flags: [])
    assert_not result["passed"]
    assert result["failed_items"].any? { |f| f.include?("總購買人數") }
  end

  test "fails when the product repurchase contradiction should have fired but did not" do
    metrics = good_metrics
    metrics["product_repurchase"] = { "products" => [{ "repurchased_this_week" => 0 }], "returning_customers_this_week" => 5, "contradiction_detected" => false }

    result = WeeklyBriefingQualityChecker.call(ai_report: good_report, metrics: metrics, risk_flags: [])
    assert_not result["passed"]
    assert result["failed_items"].any? { |f| f.include?("資料異常防呆") }
  end

  test "fails when the revenue gap arithmetic is inconsistent" do
    metrics = good_metrics
    metrics["revenue_progress"]["gap_to_beat_last_year"] = 999_999.0

    result = WeeklyBriefingQualityChecker.call(ai_report: good_report, metrics: metrics, risk_flags: [])
    assert_not result["passed"]
    assert result["failed_items"].any? { |f| f.include?("年度營收缺口") }
  end

  test "fails when the statistics period has not ended yet" do
    metrics = good_metrics
    metrics["period"]["complete"] = false

    result = WeeklyBriefingQualityChecker.call(ai_report: good_report, metrics: metrics, risk_flags: [])
    assert_not result["passed"]
    assert result["failed_items"].any? { |f| f.include?("尚未結束") }
  end

  test "fails when the data completeness score was not produced" do
    metrics = good_metrics
    metrics["data_gaps"] = {}

    result = WeeklyBriefingQualityChecker.call(ai_report: good_report, metrics: metrics, risk_flags: [])
    assert_not result["passed"]
    assert result["failed_items"].any? { |f| f.include?("資料完整度") }
  end

  test "fails when high-severity risk flags exist but the status is healthy_growth" do
    report = good_report
    report["executive_summary"]["status"] = "healthy_growth"

    result = WeeklyBriefingQualityChecker.call(ai_report: report, metrics: good_metrics, risk_flags: [{ severity: "high" }])
    assert_not result["passed"]
    assert result["failed_items"].any? { |f| f.include?("healthy_growth") }
  end
end

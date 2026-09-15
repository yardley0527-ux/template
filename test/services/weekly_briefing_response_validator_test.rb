# frozen_string_literal: true

require "test_helper"

class WeeklyBriefingResponseValidatorTest < ActiveSupport::TestCase
  def good_decision
    {
      "question" => "q", "current_situation" => "s", "data_evidence" => "d",
      "option_a" => { "action" => "a" }, "option_b" => { "action" => "b" },
      "recommended_option" => "A", "recommendation_reason" => "r",
      "impact_if_no_decision" => "i", "next_week_kpi" => "k", "confidence" => "high"
    }
  end

  def good_parsed
    {
      "executive_summary" => {
        "one_liner" => "結論", "status_basis" => "基礎",
        "top_findings" => [{ "finding" => "f" }],
        "decisions" => [good_decision],
        "biggest_risk" => { "description" => "risk" },
        "biggest_opportunity" => { "description" => "opp" }
      },
      "business_analysis" => { "revenue_and_forecast" => ["x"] }
    }
  end

  test "a fully populated response is valid" do
    result = WeeklyBriefingResponseValidator.call(good_parsed)
    assert result[:valid]
    assert_empty result[:missing_fields]
  end

  test "an entirely missing executive_summary is invalid and short-circuits" do
    result = WeeklyBriefingResponseValidator.call({ "business_analysis" => {} })
    assert_not result[:valid]
    assert_equal ["executive_summary"], result[:missing_fields]
  end

  test "an executive_summary present as an empty hash reproduces the exact production symptom (AI API succeeded, content blank) and is rejected as a single missing top-level field" do
    result = WeeklyBriefingResponseValidator.call({ "executive_summary" => {}, "business_analysis" => {} })

    assert_not result[:valid]
    assert_equal ["executive_summary"], result[:missing_fields]
  end

  test "an executive_summary with only some fields filled reports exactly which ones are still missing" do
    result = WeeklyBriefingResponseValidator.call({
      "executive_summary" => { "one_liner" => "結論", "status_basis" => "基礎" }, "business_analysis" => {}
    })

    assert_not result[:valid]
    assert_not_includes result[:missing_fields], "executive_summary.one_liner"
    assert_not_includes result[:missing_fields], "executive_summary.status_basis"
    assert_includes result[:missing_fields], "executive_summary.top_findings"
    assert_includes result[:missing_fields], "executive_summary.decisions"
    assert_includes result[:missing_fields], "executive_summary.biggest_risk"
    assert_includes result[:missing_fields], "executive_summary.biggest_opportunity"
  end

  test "blank string values (not just nil) are treated as missing" do
    parsed = good_parsed
    parsed["executive_summary"]["one_liner"] = "   "

    result = WeeklyBriefingResponseValidator.call(parsed)
    assert_includes result[:missing_fields], "executive_summary.one_liner"
  end

  test "a decision missing required fields is reported per-field with its index" do
    parsed = good_parsed
    parsed["executive_summary"]["decisions"] = [good_decision.merge("option_b" => nil, "confidence" => "")]

    result = WeeklyBriefingResponseValidator.call(parsed)
    assert_includes result[:missing_fields], "decisions[0].option_b"
    assert_includes result[:missing_fields], "decisions[0].confidence"
  end

  test "zero decisions is invalid" do
    parsed = good_parsed
    parsed["executive_summary"]["decisions"] = []

    result = WeeklyBriefingResponseValidator.call(parsed)
    assert_includes result[:missing_fields], "executive_summary.decisions"
  end
end

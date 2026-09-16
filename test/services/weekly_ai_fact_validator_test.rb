# frozen_string_literal: true

require "test_helper"

class WeeklyAiFactValidatorTest < ActiveSupport::TestCase
  def registry
    {
      "revenue.this_week" => { "metric_key" => "revenue.this_week", "raw_value" => 994_634.0, "formatted_value" => "994,634元",
                                "accepted_rounding" => 1, "period" => "本週", "kind" => "money" },
      "revenue.prev_week" => { "metric_key" => "revenue.prev_week", "raw_value" => 2_336_858.0, "formatted_value" => "2,336,858元",
                                "accepted_rounding" => 1, "period" => "上週", "kind" => "money" },
      "purchase_count.this_week" => { "metric_key" => "purchase_count.this_week", "raw_value" => 98.0, "formatted_value" => "98人",
                                       "accepted_rounding" => 0, "period" => "本週", "kind" => "count" },
      "purchase_count.growth_vs_trailing4_pct" => { "metric_key" => "purchase_count.growth_vs_trailing4_pct", "raw_value" => -36.4,
                                                      "formatted_value" => "-36.4%", "accepted_rounding" => 0.1,
                                                      "period" => "本週vs近四週平均", "kind" => "percent" },
      "revenue.growth_vs_last_year_pct" => { "metric_key" => "revenue.growth_vs_last_year_pct", "raw_value" => 16.8,
                                              "formatted_value" => "16.8%", "accepted_rounding" => 0.1,
                                              "period" => "本週vs去年同週", "kind" => "percent" },
      "new_customer.aov.this_week" => { "metric_key" => "new_customer.aov.this_week", "raw_value" => 9_670.0,
                                         "formatted_value" => "9,670元", "accepted_rounding" => 1, "period" => "本週", "kind" => "money" }
    }
  end

  def report(one_liner: nil, revenue_and_forecast: [], decisions: [])
    {
      "executive_summary" => {
        "one_liner" => one_liner,
        "biggest_risk" => { "description" => nil }, "biggest_opportunity" => { "description" => nil },
        "decisions" => decisions
      },
      "business_analysis" => { "revenue_and_forecast" => revenue_and_forecast },
      "action_items" => []
    }
  end

  test "an AI sentence using the correct raw amount passes with no issues" do
    result = WeeklyAiFactValidator.call(ai_report: report(one_liner: "本週營收994,634元，較上週明顯下降"), registry: registry)
    assert result["passed"], result["issues"].inspect
  end

  test "an AI sentence using the correct formatted amount (with thousands separators) passes" do
    result = WeeklyAiFactValidator.call(ai_report: report(revenue_and_forecast: ["本週購買人數98人，明顯減少"]), registry: registry)
    assert result["passed"], result["issues"].inspect
  end

  test "a percentage within reasonable rounding tolerance passes" do
    result = WeeklyAiFactValidator.call(ai_report: report(one_liner: "本週購買人數較近四週平均下降約36.3%"), registry: registry)
    assert result["passed"], result["issues"].inspect
  end

  test "flags a fabricated revenue number that does not exist anywhere in the registry" do
    result = WeeklyAiFactValidator.call(ai_report: report(one_liner: "本週營收高達5,000,000元，表現亮眼"), registry: registry)

    assert_not result["passed"]
    issue = result["issues"].find { |i| i["kind"] == "unverified_number" }
    assert issue, result["issues"].inspect
    assert_equal "5,000,000", issue["ai_value"]
  end

  test "flags when the AI attributes this week's revenue number to last week" do
    result = WeeklyAiFactValidator.call(ai_report: report(one_liner: "上週營收994,634元，明顯偏低"), registry: registry)

    assert_not result["passed"]
    issue = result["issues"].find { |i| i["kind"] == "period_mismatch" }
    assert issue, result["issues"].inspect
    assert_equal "上週", issue["claimed_period"]
    assert_equal "本週", issue["actual_period"]
  end

  test "flags when the AI writes a decline as an increase (direction contradicts the signed metric)" do
    result = WeeklyAiFactValidator.call(ai_report: report(one_liner: "本週購買人數較近四週平均上升36.4%，表現轉強"), registry: registry)

    assert_not result["passed"]
    issue = result["issues"].find { |i| i["kind"] == "direction_mismatch" }
    assert issue, result["issues"].inspect
    assert_equal "下降", issue["expected_direction"]
  end

  test "does not flag correctly-worded decline language as a direction mismatch" do
    result = WeeklyAiFactValidator.call(ai_report: report(one_liner: "本週購買人數較近四週平均下降36.4%"), registry: registry)
    assert result["passed"], result["issues"].inspect
  end

  test "a date is not mistaken for a revenue number" do
    result = WeeklyAiFactValidator.call(ai_report: report(one_liner: "本期報告週期為2026-09-07~2026-09-13"), registry: registry)
    assert result["passed"], result["issues"].inspect
  end

  test "a date range with slashes is not mistaken for a revenue number" do
    result = WeeklyAiFactValidator.call(ai_report: report(one_liner: "本週（09/07~09/13）營收994,634元"), registry: registry)
    assert result["passed"], result["issues"].inspect
  end

  test "P0/P1/P2 priority labels are not mistaken for financial numbers" do
    result = WeeklyAiFactValidator.call(
      ai_report: report(decisions: [{ "current_situation" => "此問題列為P0，需優先處理，本週營收994,634元" }]),
      registry: registry
    )
    assert result["passed"], result["issues"].inspect
  end

  test "reports which fields were checked and which are not yet covered by validation" do
    result = WeeklyAiFactValidator.call(ai_report: report(one_liner: "本週營收994,634元"), registry: registry)

    assert_includes result["checked_fields"], "executive_summary.one_liner"
    assert_includes result["monitored_fields"], "executive_summary.top_findings"
  end

  test "a blank field is skipped without raising" do
    result = WeeklyAiFactValidator.call(ai_report: report(one_liner: nil), registry: registry)
    assert result["passed"]
  end

  # ── 「二、降低AI fact-check誤判」：手動registry＋自動context index合併後 ──
  def merged_registry_with_product_numbers
    context = {
      "metrics" => {
        "product_repurchase" => { "products" => [
          { "product_key" => "omnipotent", "label" => "全能", "lifetime_repurchase_rate_pct" => 56.9, "overdue_count" => 2995 }
        ] }
      }
    }
    registry.merge(WeeklyAiContextValueIndex.call(context))
  end

  test "a product-level number that exists in the AI input context is verified, not flagged as fabricated" do
    result = WeeklyAiFactValidator.call(
      ai_report: report(revenue_and_forecast: ["全能歷史回購率56.9%，逾期人數2995人"]),
      registry: merged_registry_with_product_numbers
    )

    assert result["passed"], result["issues"].inspect
  end

  test "a truly nonexistent number is still flagged as invalid even after merging in the auto-indexed context" do
    result = WeeklyAiFactValidator.call(
      ai_report: report(one_liner: "本週品牌代言費用約合875,000元"),
      registry: merged_registry_with_product_numbers
    )

    assert_not result["passed"]
    assert result["issues"].any? { |i| i["kind"] == "unverified_number" }
  end

  test "REGRESSION: attributing this week's number to last week is still invalid after the registry expansion" do
    result = WeeklyAiFactValidator.call(
      ai_report: report(one_liner: "上週新客客單價9,670元，明顯偏低"),
      registry: merged_registry_with_product_numbers
    )

    assert_not result["passed"]
    issue = result["issues"].find { |i| i["kind"] == "period_mismatch" }
    assert issue, result["issues"].inspect
  end

  test "not_checked-field numbers never affect passed, even when they can't be verified at all" do
    result = WeeklyAiFactValidator.call(
      ai_report: {
        "executive_summary" => { "one_liner" => "本週營收994,634元", "top_findings" => [{ "finding" => "某商品營收暴衝至8,888,888元" }] },
        "business_analysis" => {}
      },
      registry: registry
    )

    assert result["passed"], result["issues"].inspect
    assert result["not_checked"].any? { |i| i["ai_value"] == "8,888,888" }
  end

  test "verified_count increases for numbers that match, independent of the invalid/not_checked buckets" do
    result = WeeklyAiFactValidator.call(ai_report: report(one_liner: "本週營收994,634元，購買人數98人"), registry: registry)
    assert result["verified_count"] >= 2
  end
end

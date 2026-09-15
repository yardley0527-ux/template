# frozen_string_literal: true

require "test_helper"

class WeeklyRiskFlagDetectorTest < ActiveSupport::TestCase
  def base_metrics
    {
      "new_vs_returning" => {
        "this_week" => { "new_pct" => 20.0 }, "prev_week" => { "new_pct" => 20.0 },
        "trailing4_weekly_avg" => { "new_pct" => 20.0 }
      },
      "membership" => {
        "black_gold_revenue_share_pct" => 10.0,
        "changes" => { "downgrade_count" => 1, "trailing4_weekly_avg_downgrade_count" => 1.0 }
      },
      "product_repurchase" => { "products" => [] },
      "livestreams" => { "events" => [] },
      "revenue_progress" => {
        "week_over_week_growth_pct" => 5.0,
        "required_weekly_revenue_to_beat_last_year" => 100_000,
        "trailing4_weekly_avg_revenue" => 200_000
      },
      "order_quality" => {
        "this_week_failed_rate_pct" => 1.0, "trailing4_failed_rate_pct" => 1.0,
        "this_week_unpaid_rate_pct" => 1.0, "trailing4_unpaid_rate_pct" => 1.0
      }
    }
  end

  test "returns no flags when nothing crosses a threshold" do
    assert_equal [], WeeklyRiskFlagDetector.call(base_metrics)
  end

  test "flags a new_pct decline only when it drops vs both prev_week and the trailing4 average" do
    m = base_metrics
    m["new_vs_returning"]["this_week"]["new_pct"] = 10.0 # 10pp below both prev(20) and avg4(20)

    flags = WeeklyRiskFlagDetector.call(m)
    assert_includes flags.map { |f| f[:key] }, "new_pct_declining"
  end

  test "does not flag new_pct decline when only one comparison basis dropped" do
    m = base_metrics
    m["new_vs_returning"]["prev_week"]["new_pct"] = 10.0 # dropped vs prev, but trailing4 avg still 20 (not both)

    flags = WeeklyRiskFlagDetector.call(m)
    assert_not_includes flags.map { |f| f[:key] }, "new_pct_declining"
  end

  test "flags black/gold revenue dependency above the threshold" do
    m = base_metrics
    m["membership"]["black_gold_revenue_share_pct"] = 46.0

    flags = WeeklyRiskFlagDetector.call(m)
    assert_includes flags.map { |f| f[:key] }, "black_gold_dependency"
  end

  test "flags a downgrade spike relative to the trailing4 weekly average" do
    m = base_metrics
    m["membership"]["changes"] = { "downgrade_count" => 10, "trailing4_weekly_avg_downgrade_count" => 2.0 }

    flags = WeeklyRiskFlagDetector.call(m)
    assert_includes flags.map { |f| f[:key] }, "downgrade_spike"
  end

  test "flags product overdue growth only when both the percentage and absolute increase clear their thresholds" do
    m = base_metrics
    m["product_repurchase"]["products"] = [
      { "product_key" => "p1", "label" => "P1", "overdue_count" => 100, "overdue_count_prev_week" => 95, "overdue_growth_pct" => 5.3 }, # small abs & pct increase
      { "product_key" => "p2", "label" => "P2", "overdue_count" => 50, "overdue_count_prev_week" => 30, "overdue_growth_pct" => 66.7 }   # +20, +66.7%
    ]

    flags = WeeklyRiskFlagDetector.call(m)
    product_flags = flags.select { |f| f[:key] == "product_overdue" }
    assert_equal 1, product_flags.size
    assert_equal "p2", product_flags.first.dig(:evidence, :product_key)
  end

  test "flags revenue pace behind schedule when growth is negative and required pace exceeds recent average" do
    m = base_metrics
    m["revenue_progress"]["week_over_week_growth_pct"] = -5.0
    m["revenue_progress"]["required_weekly_revenue_to_beat_last_year"] = 300_000
    m["revenue_progress"]["trailing4_weekly_avg_revenue"] = 200_000

    flags = WeeklyRiskFlagDetector.call(m)
    assert_includes flags.map { |f| f[:key] }, "revenue_pace_behind"
  end

  test "flags a payment failure/unpaid rate spike" do
    m = base_metrics
    m["order_quality"]["this_week_unpaid_rate_pct"] = 5.0

    flags = WeeklyRiskFlagDetector.call(m)
    assert_includes flags.map { |f| f[:key] }, "payment_failure_spike"
  end
end

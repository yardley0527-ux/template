# frozen_string_literal: true

require "test_helper"

class WeeklyRiskFlagDetectorTest < ActiveSupport::TestCase
  def base_metrics
    {
      "revenue_progress" => {
        "already_beat_last_year" => true,
        "required_weekly_revenue_to_beat_last_year" => nil,
        "this_week_revenue" => 100_000.0,
        "prev_week_revenue" => 95_000.0,
        "week_before_prev_revenue" => 90_000.0,
        "comparable_basis" => { "growth_pct" => 5.0, "basis_label" => "近4個一般自然週平均", "sample_size" => 4 },
        "revenue_concentration" => {
          "top_customer_share_pct" => 2.0, "top_level_share_pct" => 20.0, "top_level_name" => "銀卡",
          "top_product_share_pct" => 15.0, "top_product_name" => "代謝錠", "top_livestream_share_pct" => 0.0
        }
      },
      "new_vs_returning" => {
        "this_week"            => { "new_customers" => 20, "new_pct" => 20.0, "new_aov" => 5000.0, "returning_customers" => 80, "returning_aov" => 8000.0 },
        "prev_week"            => { "new_customers" => 20, "new_aov" => 5000.0 },
        "week_before_prev"     => { "new_customers" => 20 },
        "trailing4_weekly_avg" => { "new_customers" => 20.0, "returning_customers" => 80.0, "returning_aov" => 8000.0 },
        "cohort_repurchase"    => [
          { "window_days" => 30, "repurchase_rate_pct" => 15.0, "prev_cohort_rate_pct" => 15.0, "sample_sufficient" => true }
        ]
      },
      "product_repurchase" => { "products" => [] },
      "membership" => {
        "black_gold_revenue_share_pct" => 10.0,
        "changes" => { "downgrade_count" => 1, "upgrade_count" => 5, "trailing4_weekly_avg_downgrade_count" => 1.0 },
        "levels" => [
          { "level" => "銀卡", "active_rate_pct" => 70.0 }, { "level" => "金卡", "active_rate_pct" => 70.0 }, { "level" => "黑卡", "active_rate_pct" => 70.0 }
        ]
      },
      "order_quality" => {
        "this_week_failed_rate_pct" => 1.0, "trailing4_failed_rate_pct" => 1.0,
        "this_week_unpaid_rate_pct" => 1.0, "trailing4_unpaid_rate_pct" => 1.0
      },
      "data_quality" => {
        "product_cycle_contradiction_detected" => false, "stale_product_cycles" => [],
        "membership_unclassified_revenue_pct" => 2.0, "last_year_same_week_data_incomplete" => false,
        "stale_livestream_stats" => []
      }
    }
  end

  test "returns no flags when nothing crosses a threshold" do
    assert_equal [], WeeklyRiskFlagDetector.call(base_metrics)
  end

  test "every flag carries a severity and category" do
    m = base_metrics
    m["membership"]["black_gold_revenue_share_pct"] = 46.0

    flags = WeeklyRiskFlagDetector.call(m)
    assert flags.all? { |f| f[:severity].present? && f[:category].present? }
  end

  # ── 營收風險 ─────────────────────────────────────────────────
  test "flags revenue below the required weekly pace, with high severity when the shortfall is severe" do
    m = base_metrics
    m["revenue_progress"]["already_beat_last_year"] = false
    m["revenue_progress"]["required_weekly_revenue_to_beat_last_year"] = 200_000.0
    m["revenue_progress"]["this_week_revenue"] = 100_000.0 # 50% short

    flags = WeeklyRiskFlagDetector.call(m)
    f = flags.find { |x| x[:key] == "revenue_below_required_pace" }
    assert f
    assert_equal "high", f[:severity]
  end

  test "flags a comparable-basis revenue drop of 30% or more" do
    m = base_metrics
    m["revenue_progress"]["comparable_basis"]["growth_pct"] = -35.0

    flags = WeeklyRiskFlagDetector.call(m)
    assert_includes flags.map { |f| f[:key] }, "revenue_comparable_basis_drop"
  end

  test "flags consecutive two-week revenue decline" do
    m = base_metrics
    m["revenue_progress"]["this_week_revenue"] = 80_000.0
    m["revenue_progress"]["prev_week_revenue"] = 90_000.0
    m["revenue_progress"]["week_before_prev_revenue"] = 100_000.0

    flags = WeeklyRiskFlagDetector.call(m)
    assert_includes flags.map { |f| f[:key] }, "consecutive_revenue_decline"
  end

  test "flags revenue concentration in a single product above threshold" do
    m = base_metrics
    m["revenue_progress"]["revenue_concentration"]["top_product_share_pct"] = 55.0

    flags = WeeklyRiskFlagDetector.call(m)
    assert_includes flags.map { |f| f[:key] }, "revenue_concentration_product"
  end

  test "flags a payment failure/unpaid rate spike" do
    m = base_metrics
    m["order_quality"]["this_week_unpaid_rate_pct"] = 5.0

    flags = WeeklyRiskFlagDetector.call(m)
    assert_includes flags.map { |f| f[:key] }, "payment_failure_spike"
  end

  # ── 新客風險 ─────────────────────────────────────────────────
  test "flags new customer count dropping 30%+ vs the trailing4 average" do
    m = base_metrics
    m["new_vs_returning"]["this_week"]["new_customers"] = 10 # 50% below avg4 of 20

    flags = WeeklyRiskFlagDetector.call(m)
    assert_includes flags.map { |f| f[:key] }, "new_customer_drop_vs_avg4"
  end

  test "flags new customer pct below the minimum" do
    m = base_metrics
    m["new_vs_returning"]["this_week"]["new_pct"] = 5.0

    flags = WeeklyRiskFlagDetector.call(m)
    assert_includes flags.map { |f| f[:key] }, "new_customer_pct_too_low"
  end

  test "flags two consecutive weeks of new customer decline" do
    m = base_metrics
    m["new_vs_returning"]["this_week"]["new_customers"] = 10
    m["new_vs_returning"]["prev_week"]["new_customers"] = 15
    m["new_vs_returning"]["week_before_prev"]["new_customers"] = 20

    flags = WeeklyRiskFlagDetector.call(m)
    assert_includes flags.map { |f| f[:key] }, "new_customer_two_week_decline"
  end

  test "flags new customer AOV rising while count drops significantly" do
    m = base_metrics
    m["new_vs_returning"]["this_week"]["new_aov"] = 6000.0
    m["new_vs_returning"]["this_week"]["new_customers"] = 10
    m["new_vs_returning"]["prev_week"]["new_aov"] = 5000.0
    m["new_vs_returning"]["prev_week"]["new_customers"] = 20

    flags = WeeklyRiskFlagDetector.call(m)
    assert_includes flags.map { |f| f[:key] }, "new_customer_aov_up_but_count_down"
  end

  # ── 舊客風險 ─────────────────────────────────────────────────
  test "flags returning customer count dropping 20%+ vs the trailing4 average" do
    m = base_metrics
    m["new_vs_returning"]["this_week"]["returning_customers"] = 60 # 25% below avg4 of 80

    flags = WeeklyRiskFlagDetector.call(m)
    assert_includes flags.map { |f| f[:key] }, "returning_customer_drop_vs_avg4"
  end

  test "flags returning AOV dropping 20%+ vs the trailing4 average" do
    m = base_metrics
    m["new_vs_returning"]["this_week"]["returning_aov"] = 6000.0 # 25% below avg4 of 8000

    flags = WeeklyRiskFlagDetector.call(m)
    assert_includes flags.map { |f| f[:key] }, "returning_aov_drop_vs_avg4"
  end

  test "flags a cohort repurchase rate drop only when the cohort sample is sufficient" do
    m = base_metrics
    m["new_vs_returning"]["cohort_repurchase"][0]["repurchase_rate_pct"] = 10.0
    m["new_vs_returning"]["cohort_repurchase"][0]["prev_cohort_rate_pct"] = 15.0 # -33%
    m["new_vs_returning"]["cohort_repurchase"][0]["sample_sufficient"] = false

    assert_not_includes WeeklyRiskFlagDetector.call(m).map { |f| f[:key] }, "cohort_repurchase_rate_drop"

    m["new_vs_returning"]["cohort_repurchase"][0]["sample_sufficient"] = true
    assert_includes WeeklyRiskFlagDetector.call(m).map { |f| f[:key] }, "cohort_repurchase_rate_drop"
  end

  test "flags product overdue growth only when both the percentage and absolute increase clear their thresholds, and skips stale products" do
    m = base_metrics
    m["product_repurchase"]["products"] = [
      { "product_key" => "p1", "label" => "P1", "overdue_count" => 100, "overdue_count_prev_week" => 95, "overdue_growth_pct" => 5.3 }, # too small
      { "product_key" => "p2", "label" => "P2", "overdue_count" => 50, "overdue_count_prev_week" => 30, "overdue_growth_pct" => 66.7 },  # +20, +66.7%
      { "product_key" => "p3", "label" => "P3", "overdue_count" => 50, "overdue_count_prev_week" => 10, "overdue_growth_pct" => nil }    # stale cache, must be skipped
    ]

    flags = WeeklyRiskFlagDetector.call(m)
    product_flags = flags.select { |f| f[:key] == "product_overdue_increasing" }
    assert_equal 1, product_flags.size
    assert_equal "p2", product_flags.first.dig(:evidence, :product_key)
  end

  # ── 會員風險 ─────────────────────────────────────────────────
  test "flags downgrade exceeding upgrade, with high severity at 2x or more" do
    m = base_metrics
    m["membership"]["changes"] = { "downgrade_count" => 10, "upgrade_count" => 4, "trailing4_weekly_avg_downgrade_count" => 1.0 }

    flags = WeeklyRiskFlagDetector.call(m)
    f = flags.find { |x| x[:key] == "downgrade_exceeds_upgrade" }
    assert f
    assert_equal "high", f[:severity]
  end

  test "flags a downgrade spike relative to the trailing4 weekly average" do
    m = base_metrics
    m["membership"]["changes"] = { "downgrade_count" => 10, "upgrade_count" => 20, "trailing4_weekly_avg_downgrade_count" => 2.0 }

    flags = WeeklyRiskFlagDetector.call(m)
    assert_includes flags.map { |f| f[:key] }, "downgrade_spike_vs_avg4"
  end

  test "flags low active rate for mid/high tiers only, not white/normal cards" do
    m = base_metrics
    m["membership"]["levels"] = [
      { "level" => "銀卡", "active_rate_pct" => 30.0 }, { "level" => "白卡", "active_rate_pct" => 5.0 }
    ]

    flags = WeeklyRiskFlagDetector.call(m).select { |f| f[:key] == "mid_high_tier_low_active_rate" }
    assert_equal 1, flags.size
    assert_equal "銀卡", flags.first.dig(:evidence, :level)
  end

  test "flags black/gold revenue dependency above the threshold" do
    m = base_metrics
    m["membership"]["black_gold_revenue_share_pct"] = 46.0

    flags = WeeklyRiskFlagDetector.call(m)
    assert_includes flags.map { |f| f[:key] }, "black_gold_dependency"
  end

  # ── 資料品質風險 ─────────────────────────────────────────────
  test "flags product repurchase data contradiction as a data_anomaly" do
    m = base_metrics
    m["data_quality"]["product_cycle_contradiction_detected"] = true

    f = WeeklyRiskFlagDetector.call(m).find { |x| x[:key] == "product_repurchase_data_contradiction" }
    assert f
    assert_equal "data_anomaly", f[:severity]
  end

  test "flags membership revenue reconciliation gap above threshold" do
    m = base_metrics
    m["data_quality"]["membership_unclassified_revenue_pct"] = 15.0

    assert_includes WeeklyRiskFlagDetector.call(m).map { |f| f[:key] }, "membership_revenue_reconciliation_gap"
  end

  test "flags incomplete last-year same-week data" do
    m = base_metrics
    m["data_quality"]["last_year_same_week_data_incomplete"] = true

    assert_includes WeeklyRiskFlagDetector.call(m).map { |f| f[:key] }, "last_year_same_week_data_missing"
  end

  test "flags stale livestream stats" do
    m = base_metrics
    m["data_quality"]["stale_livestream_stats"] = [{ "date" => "2026-06-01", "title" => "x" }]

    assert_includes WeeklyRiskFlagDetector.call(m).map { |f| f[:key] }, "livestream_stats_stale"
  end

  # ── 新客/舊客二段式門檻（黃20%/紅30%）───────────────────────────
  test "new customer drop is yellow (medium) between 20% and 30%, and red (high) at 30%+" do
    m = base_metrics
    m["new_vs_returning"]["this_week"]["new_customers"] = 16 # 20% below avg4 of 20
    yellow = WeeklyRiskFlagDetector.call(m).find { |f| f[:key] == "new_customer_drop_vs_avg4" }
    assert_equal "medium", yellow[:severity]

    m["new_vs_returning"]["this_week"]["new_customers"] = 5 # 75% below avg4 of 20 (fixture-style drop)
    red = WeeklyRiskFlagDetector.call(m).find { |f| f[:key] == "new_customer_drop_vs_avg4" }
    assert_equal "high", red[:severity]
  end

  test "returning customer drop is yellow at 20% and red at 30%+" do
    m = base_metrics
    m["new_vs_returning"]["this_week"]["returning_customers"] = 64 # 20% below avg4 of 80
    yellow = WeeklyRiskFlagDetector.call(m).find { |f| f[:key] == "returning_customer_drop_vs_avg4" }
    assert_equal "medium", yellow[:severity]

    m["new_vs_returning"]["this_week"]["returning_customers"] = 50 # 37.5% below avg4 of 80
    red = WeeklyRiskFlagDetector.call(m).find { |f| f[:key] == "returning_customer_drop_vs_avg4" }
    assert_equal "high", red[:severity]
  end

  # ── 整體客單價二段式門檻（黃10%/紅20%）───────────────────────────
  test "overall AOV drop is yellow at 10% and red at 20%+, reading from decomposition" do
    m = base_metrics
    m["new_vs_returning"]["decomposition"] = { "overall_aov_growth_vs_trailing4_pct" => -12.0 }
    yellow = WeeklyRiskFlagDetector.call(m).find { |f| f[:key] == "overall_aov_drop_vs_avg4" }
    assert_equal "medium", yellow[:severity]

    m["new_vs_returning"]["decomposition"] = { "overall_aov_growth_vs_trailing4_pct" => -40.0 }
    red = WeeklyRiskFlagDetector.call(m).find { |f| f[:key] == "overall_aov_drop_vs_avg4" }
    assert_equal "high", red[:severity]
  end

  test "no overall AOV flag when decomposition is absent or within threshold" do
    m = base_metrics
    assert_nil WeeklyRiskFlagDetector.call(m).find { |f| f[:key] == "overall_aov_drop_vs_avg4" }

    m["new_vs_returning"]["decomposition"] = { "overall_aov_growth_vs_trailing4_pct" => -3.0 }
    assert_nil WeeklyRiskFlagDetector.call(m).find { |f| f[:key] == "overall_aov_drop_vs_avg4" }
  end

  # ── 缺貨風險規則（四條件任一命中即紅燈）───────────────────────────
  def stockout_product(overrides = {})
    {
      "product_key" => "metabolism", "label" => "代謝錠", "availability_status" => "out_of_stock",
      "lifetime_repurchase_rate_pct" => 10.0, "actionability" => { "actionable_count" => 5 },
      "trailing4_revenue_share_pct" => 1.0, "expected_restock_date" => Date.current + 10
    }.merge(overrides)
  end

  test "flags stockout risk when the historical repurchase rate is 40%+" do
    m = base_metrics
    m["product_repurchase"]["products"] = [stockout_product("lifetime_repurchase_rate_pct" => 56.9)]

    f = WeeklyRiskFlagDetector.call(m).find { |x| x[:key] == "product_stockout_risk" }
    assert f
    assert_equal "high", f[:severity]
    assert_includes f[:evidence][:reasons].join, "歷史回購率"
  end

  test "flags stockout risk when actionable repurchase count is 100+" do
    m = base_metrics
    m["product_repurchase"]["products"] = [stockout_product("actionability" => { "actionable_count" => 120 })]

    assert WeeklyRiskFlagDetector.call(m).any? { |f| f[:key] == "product_stockout_risk" }
  end

  test "flags stockout risk when the product is 10%+ of trailing4 revenue" do
    m = base_metrics
    m["product_repurchase"]["products"] = [stockout_product("trailing4_revenue_share_pct" => 11.0)]

    assert WeeklyRiskFlagDetector.call(m).any? { |f| f[:key] == "product_stockout_risk" }
  end

  test "flags stockout risk when there is no expected restock date" do
    m = base_metrics
    m["product_repurchase"]["products"] = [stockout_product("expected_restock_date" => nil)]

    assert WeeklyRiskFlagDetector.call(m).any? { |f| f[:key] == "product_stockout_risk" }
  end

  test "does not flag stockout risk for in-stock products even if repurchase rate is high" do
    m = base_metrics
    m["product_repurchase"]["products"] = [stockout_product("availability_status" => "in_stock", "lifetime_repurchase_rate_pct" => 90.0)]

    assert_nil WeeklyRiskFlagDetector.call(m).find { |f| f[:key] == "product_stockout_risk" }
  end

  # ── 連續兩週紅燈（新客）／連續兩週淨降級 ──────────────────────────
  test "flags new_customer_two_consecutive_red only when this week and last week were both red" do
    m = base_metrics
    m["new_vs_returning"]["this_week"]["new_customers"] = 5 # red this week (75% below avg4)

    no_history = WeeklyRiskFlagDetector.call(m, previous_week_flags: [])
    assert_nil no_history.find { |f| f[:key] == "new_customer_two_consecutive_red" }

    last_week_not_red = WeeklyRiskFlagDetector.call(m, previous_week_flags: [{ key: "new_customer_drop_vs_avg4", severity: "medium" }])
    assert_nil last_week_not_red.find { |f| f[:key] == "new_customer_two_consecutive_red" }

    last_week_red = WeeklyRiskFlagDetector.call(m, previous_week_flags: [{ key: "new_customer_drop_vs_avg4", severity: "high" }])
    assert_includes last_week_red.map { |f| f[:key] }, "new_customer_two_consecutive_red"
  end

  test "flags membership_consecutive_net_downgrade only when both weeks have a negative net" do
    m = base_metrics
    m["membership"]["changes"] = { "upgrade_count" => 1, "downgrade_count" => 3, "prev_week_net" => -2,
                                    "trailing4_weekly_avg_downgrade_count" => 1.0 }

    f = WeeklyRiskFlagDetector.call(m).find { |x| x[:key] == "membership_consecutive_net_downgrade" }
    assert f
    assert_equal "high", f[:severity]

    m["membership"]["changes"]["prev_week_net"] = 1 # last week was positive
    assert_nil WeeklyRiskFlagDetector.call(m).find { |x| x[:key] == "membership_consecutive_net_downgrade" }
  end
end

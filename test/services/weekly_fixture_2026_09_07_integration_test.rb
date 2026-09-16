# frozen_string_literal: true

require "test_helper"

# 端到端驗證使用者規格書「十四、針對本期資料的預期判讀」（2026/09/07~09/13）：
# 串起 WeeklyRiskFlagDetector／WeeklyBusinessSignalClassifier／
# WeeklyHeadlineClassifier／WeeklyActionItemBuilder，確認組合起來的行為符合
# 規格列出的質化預期（新客紅燈、全能缺貨紅燈、週型標題、不得顯示「本週未
# 觸發任何風險旗標」等）。new_vs_returning 區塊直接沿用題目給定的精確數字
# （已在 weekly_revenue_decomposition_test.rb 驗證過拆解公式本身），
# revenue_progress／product_repurchase／membership 等其餘區塊用結構相符的
# 最小必要資料模擬，不依賴完整歷史訂單資料庫（那部分需要正式站真實資料才
# 能重建，不在單元測試範圍內）。
class WeeklyFixture20260907IntegrationTest < ActiveSupport::TestCase
  setup do
    @period = WeeklyPeriod.new(Date.new(2026, 9, 7))
    # 「上週有直播活動」——落在 8/31~9/6（prev_week_range）內，讓
    # WeeklyHeadlineClassifier 判斷出「活動後回落週」。
    Livestream.create!(date: Date.new(2026, 9, 4), total_orders: 100, total_revenue: 500_000, total_buyers: 90, new_buyers: 10)
  end

  def decomposition_service
    WeeklyMetricsService.new(@period.week_start)
  end

  def fixture_metrics
    this_week = {
      "new_customers" => 5, "returning_customers" => 93,
      "new_revenue" => 48_349.0, "returning_revenue" => 946_285.0,
      "total_customers" => 98, "total_revenue" => 994_634.0,
      "new_aov" => 9_670.0, "returning_aov" => 10_175.0, "new_pct" => (5 * 100.0 / 98)
    }
    trailing4_avg = {
      "new_customers" => 17, "returning_customers" => 137,
      "new_revenue" => 177_137.0, "returning_revenue" => 2_426_820.0,
      "total_customers" => 154, "total_revenue" => 2_603_957.0,
      "new_aov" => 10_420.0, "returning_aov" => 17_714.0
    }
    last_year_same_week = {
      "new_customers" => 10, "returning_customers" => 105,
      "new_revenue" => 66_194.0, "returning_revenue" => 785_035.0,
      "total_customers" => 115, "total_revenue" => 851_229.0,
      "new_aov" => 6_619.0, "returning_aov" => 7_477.0
    }
    decomposition = decomposition_service.send(:build_revenue_decomposition, this_week, trailing4_avg, last_year_same_week)

    {
      "period" => @period.as_json,
      "week_type" => { "type" => "normal_week", "type_label" => "一般自然週", "campaign_size_note" => nil },
      "revenue_progress" => {
        "already_beat_last_year" => true, "required_weekly_revenue_to_beat_last_year" => nil,
        "this_week_revenue" => 994_634.0, "prev_week_revenue" => 2_336_858.0, "week_before_prev_revenue" => 1_800_000.0,
        "comparable_basis" => { "growth_pct" => decomposition["revenue_growth_vs_trailing4_pct"], "basis_label" => "近4個一般自然週平均", "sample_size" => 4 },
        "revenue_concentration" => { "top_customer_share_pct" => 2.0, "top_level_share_pct" => 20.0, "top_level_name" => "銀卡",
                                      "top_product_share_pct" => 15.0, "top_product_name" => "膠原蛋白", "top_livestream_share_pct" => 0.0 }
      },
      "new_vs_returning" => {
        "this_week" => this_week, "prev_week" => { "new_customers" => 15, "new_aov" => 9_000.0 },
        "week_before_prev" => { "new_customers" => 18 },
        "trailing4_weekly_avg" => trailing4_avg, "last_year_same_week" => last_year_same_week,
        "decomposition" => decomposition,
        "cohort_repurchase" => [{ "window_days" => 30, "repurchase_rate_pct" => 12.0, "prev_cohort_rate_pct" => 13.0, "sample_sufficient" => true }]
      },
      "product_repurchase" => {
        "products" => [
          { "product_key" => "omnipotent", "label" => "全能", "availability_status" => "out_of_stock",
            "lifetime_repurchase_rate_pct" => 56.9, "actionability" => { "actionable_count" => 10 },
            "trailing4_revenue_share_pct" => 2.0, "expected_restock_date" => nil,
            "overdue_count" => 50, "overdue_count_prev_week" => 48, "overdue_growth_pct" => 4.2 }
        ]
      },
      "membership" => {
        "black_gold_revenue_share_pct" => 10.0,
        "changes" => { "downgrade_count" => 0, "upgrade_count" => 0, "trailing4_weekly_avg_downgrade_count" => 0.0, "prev_week_net" => nil },
        "levels" => []
      },
      "order_quality" => { "this_week_failed_rate_pct" => 0.5, "trailing4_failed_rate_pct" => 0.5,
                            "this_week_unpaid_rate_pct" => 0.5, "trailing4_unpaid_rate_pct" => 0.5 },
      "data_quality" => { "product_cycle_contradiction_detected" => false, "stale_product_cycles" => [],
                           "membership_unclassified_revenue_pct" => 0.0, "last_year_same_week_data_incomplete" => false,
                           "stale_livestream_stats" => [] }
    }
  end

  test "new customer drop is a red (high) flag" do
    flags = WeeklyRiskFlagDetector.call(fixture_metrics)
    f = flags.find { |x| x[:key] == "new_customer_drop_vs_avg4" }
    assert f, "new_customer_drop_vs_avg4 should fire (70.6% drop)"
    assert_equal "high", f[:severity]
  end

  test "全能 stockout with 56.9% historical repurchase rate and no restock date is a red flag" do
    flags = WeeklyRiskFlagDetector.call(fixture_metrics)
    f = flags.find { |x| x[:key] == "product_stockout_risk" }
    assert f
    assert_equal "high", f[:severity]
    assert_includes f[:evidence][:label], "全能"
  end

  test "risk flags are never empty for this fixture (must not render 本週未觸發任何風險旗標)" do
    flags = WeeklyRiskFlagDetector.call(fixture_metrics)
    assert flags.any?
  end

  test "headline is 活動後回落／新客不足警戒週" do
    metrics = fixture_metrics
    risk_flags = WeeklyRiskFlagDetector.call(metrics)
    signals = WeeklyBusinessSignalClassifier.call(metrics, risk_flags)["signals"]
    headline = WeeklyHeadlineClassifier.call(period: @period, metrics: metrics, risk_flags: risk_flags, business_signals: signals)

    assert_equal "活動後回落／新客不足警戒週", headline["display"]
  end

  test "new_customer and product_inventory business signals are both red" do
    metrics = fixture_metrics
    risk_flags = WeeklyRiskFlagDetector.call(metrics)
    signals = WeeklyBusinessSignalClassifier.call(metrics, risk_flags)["signals"]

    assert_equal "red", signals.find { |s| s["area"] == "new_customer" }["status"]
    assert_equal "red", signals.find { |s| s["area"] == "product_inventory" }["status"]
  end

  test "action items include P0 entries for both the new customer shortfall and the 全能 stockout, capped at 5" do
    metrics = fixture_metrics
    risk_flags = WeeklyRiskFlagDetector.call(metrics)
    items = WeeklyActionItemBuilder.call(period: @period, risk_flags: risk_flags)

    assert items.size <= 5
    assert items.any? { |i| i[:priority] == "P0" && i[:problem].include?("新客") }
    assert items.any? { |i| i[:priority] == "P0" && i[:problem].include?("全能") }
  end

  test "purchase-count-and-AOV both declined, yet revenue is still above last year — the yoy caveat must be present" do
    d = fixture_metrics["new_vs_returning"]["decomposition"]
    assert_equal "both", d["decline_driver"]
    assert d["yoy_still_positive_caveat"]
  end
end

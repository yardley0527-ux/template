# frozen_string_literal: true

require "test_helper"

# 純數學拆解邏輯（規格三：總購買人數／整體客單價／人數客單價雙重下降判讀），
# 直接餵入題目給定的 2026/09/07~09/13 fixture 數字驗證，不經過真實資料庫查詢
# （trailing4/last_year 的原始資料在本機測試環境不存在，這裡驗證的是「拆解
# 公式本身算得對不對」，不是「近四週平均查詢邏輯」）。
class WeeklyRevenueDecompositionTest < ActiveSupport::TestCase
  setup do
    @service = WeeklyMetricsService.new(Date.new(2026, 9, 7))

    @this_week = {
      "new_customers" => 5, "returning_customers" => 93,
      "new_revenue" => 48_349.0, "returning_revenue" => 946_285.0,
      "total_customers" => 98, "total_revenue" => 994_634.0,
      "new_aov" => 9_670.0, "returning_aov" => 10_175.0
    }
    @trailing4_avg = {
      "new_customers" => 17, "returning_customers" => 137,
      "new_revenue" => 177_137.0, "returning_revenue" => 2_426_820.0,
      "total_customers" => 154, "total_revenue" => 2_603_957.0,
      "new_aov" => 10_420.0, "returning_aov" => 17_714.0
    }
    @last_year_same_week = {
      "new_customers" => 10, "returning_customers" => 105,
      "new_revenue" => 66_194.0, "returning_revenue" => 785_035.0,
      "total_customers" => 115, "total_revenue" => 851_229.0,
      "new_aov" => 6_619.0, "returning_aov" => 7_477.0
    }
  end

  def decomposition
    @service.send(:build_revenue_decomposition, @this_week, @trailing4_avg, @last_year_same_week)
  end

  test "purchase count and overall AOV are decomposed and compared against trailing4/last year exactly as specified" do
    d = decomposition

    assert_equal 10_149.33, d["this_week_overall_aov"]
    assert_equal 16_908.81, d["trailing4_weekly_avg_overall_aov"] # 使用者原文寫「約16,909」，此為精確值

    assert_in_delta(-36.4, d["customers_growth_vs_trailing4_pct"], 0.1)
    assert_in_delta(-40.0, d["overall_aov_growth_vs_trailing4_pct"], 0.1)
    assert_in_delta(-61.8, d["revenue_growth_vs_trailing4_pct"], 0.1)

    assert_in_delta 16.8, d["revenue_growth_vs_last_year_pct"], 0.1
    assert_in_delta(-70.6, d["new_customers_growth_vs_trailing4_pct"], 0.1)
    assert_in_delta(-50.0, d["new_customers_growth_vs_last_year_pct"], 0.1)
    assert_in_delta 20.5, d["returning_revenue_growth_vs_last_year_pct"], 0.1
    assert_in_delta 36.1, d["returning_aov_growth_vs_last_year_pct"], 0.1
  end

  test "diagnoses simultaneous decline in purchase count and AOV, with a year-over-year caveat" do
    d = decomposition

    assert_equal "both", d["decline_driver"]
    assert d["yoy_still_positive_caveat"], "本週營收仍高於去年同週，不能直接判斷為全面衰退"
    assert_match(/16.8/, d["yoy_caveat_note"])
  end

  test "reports no decline when neither purchase count nor AOV dropped beyond the threshold" do
    flat_trailing4 = @trailing4_avg.merge("total_customers" => 98, "total_revenue" => 994_634.0)
    service = WeeklyMetricsService.new(Date.new(2026, 9, 7))
    d = service.send(:build_revenue_decomposition, @this_week, flat_trailing4, @last_year_same_week)

    assert_equal "neither", d["decline_driver"]
    assert_not d["yoy_still_positive_caveat"]
  end

  test "does not raise and returns nil growth rates when a comparison base has zero customers/revenue" do
    zero_last_year = { "new_customers" => 0, "returning_customers" => 0, "new_revenue" => 0.0, "returning_revenue" => 0.0,
                        "total_customers" => 0, "total_revenue" => 0.0, "new_aov" => 0.0, "returning_aov" => 0.0 }
    service = WeeklyMetricsService.new(Date.new(2026, 9, 7))

    d = nil
    assert_nothing_raised { d = service.send(:build_revenue_decomposition, @this_week, @trailing4_avg, zero_last_year) }

    assert_nil d["revenue_growth_vs_last_year_pct"]
    assert_nil d["customers_growth_vs_last_year_pct"]
    assert_nil d["new_customers_growth_vs_last_year_pct"]
    assert_equal 0.0, d["last_year_same_week_overall_aov"] # safe_div 對 0/0 回傳 0.0，不丟例外
  end

  test "isolates customer-count-only decline from AOV-only decline" do
    people_only_trailing4 = @trailing4_avg.merge(
      "total_customers" => 154,
      "total_revenue" => 1_562_995.28 # AOV ≈ 10,149 (same as this week), so only customer count drives the drop
    )
    service = WeeklyMetricsService.new(Date.new(2026, 9, 7))
    d = service.send(:build_revenue_decomposition, @this_week, people_only_trailing4, @last_year_same_week)
    assert_equal "customer_count", d["decline_driver"]

    aov_only_trailing4 = @trailing4_avg.merge("total_customers" => 98, "total_revenue" => 2_603_957.0)
    d2 = service.send(:build_revenue_decomposition, @this_week, aov_only_trailing4, @last_year_same_week)
    assert_equal "aov", d2["decline_driver"]
  end
end

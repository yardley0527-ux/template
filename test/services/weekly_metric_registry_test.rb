# frozen_string_literal: true

require "test_helper"

class WeeklyMetricRegistryTest < ActiveSupport::TestCase
  def decomposition_service
    WeeklyMetricsService.new(Date.new(2026, 9, 7))
  end

  # 沿用使用者規格書「十四」給定的2026/09/07~09/13 fixture數字。
  def fixture_metrics
    this_week = {
      "new_customers" => 5, "returning_customers" => 93,
      "new_revenue" => 48_349.0, "returning_revenue" => 946_285.0,
      "total_customers" => 98, "total_revenue" => 994_634.0,
      "new_aov" => 9_670.0, "returning_aov" => 10_175.0
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
      "new_vs_returning" => {
        "this_week" => this_week, "prev_week" => { "total_revenue" => 2_336_858.0 },
        "trailing4_weekly_avg" => trailing4_avg, "last_year_same_week" => last_year_same_week,
        "decomposition" => decomposition
      },
      "revenue_progress" => {
        "ytd_revenue" => 86_412_850.0, "last_year_same_period_ytd_revenue" => 83_480_524.0,
        "last_year_full_year_revenue" => 112_835_149.0, "gap_to_beat_last_year" => 112_835_149.0 - 86_412_850.0
      }
    }
  end

  test "registers this-week and prev-week revenue with the correct raw values and periods" do
    registry = WeeklyMetricRegistry.call(fixture_metrics)

    assert_equal 994_634.0, registry["revenue.this_week"]["raw_value"]
    assert_equal "本週", registry["revenue.this_week"]["period"]
    assert_equal 2_336_858.0, registry["revenue.prev_week"]["raw_value"]
    assert_equal "上週", registry["revenue.prev_week"]["period"]
  end

  test "formats money with thousands separators and a 元 suffix" do
    registry = WeeklyMetricRegistry.call(fixture_metrics)
    assert_equal "994,634元", registry["revenue.this_week"]["formatted_value"]
  end

  test "registers purchase-count decomposition matching the spec's expected numbers" do
    registry = WeeklyMetricRegistry.call(fixture_metrics)

    assert_equal 98, registry["purchase_count.this_week"]["raw_value"]
    assert_equal 154, registry["purchase_count.trailing4_avg"]["raw_value"]
    assert_in_delta(-36.4, registry["purchase_count.growth_vs_trailing4_pct"]["raw_value"], 0.1)
  end

  test "registers overall AOV matching the spec's expected numbers" do
    registry = WeeklyMetricRegistry.call(fixture_metrics)

    assert_in_delta(10_149, registry["aov.this_week"]["raw_value"], 1)
    assert_in_delta(16_909, registry["aov.trailing4_avg"]["raw_value"], 1)
    assert_in_delta(-40.0, registry["aov.growth_vs_trailing4_pct"]["raw_value"], 0.1)
  end

  test "registers year-to-date revenue progress figures" do
    registry = WeeklyMetricRegistry.call(fixture_metrics)

    assert_equal 86_412_850.0, registry["revenue_progress.ytd"]["raw_value"]
    assert_equal 112_835_149.0, registry["revenue_progress.last_year_full_year"]["raw_value"]
  end

  test "skips a metric entirely when its raw value is nil, rather than registering a garbage entry" do
    metrics = fixture_metrics
    metrics["revenue_progress"].delete("ytd_revenue")

    registry = WeeklyMetricRegistry.call(metrics)
    assert_not registry.key?("revenue_progress.ytd")
  end

  test "each entry carries an accepted_rounding matching its kind (money=1, count=0, percent=0.1)" do
    registry = WeeklyMetricRegistry.call(fixture_metrics)

    assert_equal 1, registry["revenue.this_week"]["accepted_rounding"]
    assert_equal 0, registry["purchase_count.this_week"]["accepted_rounding"]
    assert_equal 0.1, registry["purchase_count.growth_vs_trailing4_pct"]["accepted_rounding"]
  end
end

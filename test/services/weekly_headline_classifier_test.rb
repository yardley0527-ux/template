# frozen_string_literal: true

require "test_helper"

class WeeklyHeadlineClassifierTest < ActiveSupport::TestCase
  setup do
    @week_start = Date.new(2026, 9, 7)
    @period = WeeklyPeriod.new(@week_start)
  end

  def flag(key, category, severity)
    { key: key, category: category, severity: severity, evidence: {} }
  end

  def metrics(type: "normal_week", label: "一般自然週")
    { "week_type" => { "type" => type, "type_label" => label } }
  end

  test "normal week with no event last week and no warnings is a plain 一般經營週" do
    result = WeeklyHeadlineClassifier.call(period: @period, metrics: metrics, risk_flags: [], business_signals: [])
    assert_equal "一般經營週", result["display"]
  end

  test "a livestream week with no high-severity revenue flag is 活動成長週" do
    result = WeeklyHeadlineClassifier.call(period: @period, metrics: metrics(type: "livestream_week", label: "直播週"),
                                            risk_flags: [], business_signals: [])
    assert_equal "活動成長週", result["labels"].first
  end

  test "post-event pullback fires when last week had a livestream but this week does not" do
    Livestream.create!(date: @period.prev_week_start + 3, total_orders: 1, total_revenue: 1000, total_buyers: 1, new_buyers: 1)

    result = WeeklyHeadlineClassifier.call(period: @period, metrics: metrics, risk_flags: [], business_signals: [])
    assert_equal "post_event_pullback", result["primary_key"]
    assert result["prev_week_had_event"]
  end

  test "combines post-event pullback with the highest-priority active warning" do
    Livestream.create!(date: @period.prev_week_start + 3, total_orders: 1, total_revenue: 1000, total_buyers: 1, new_buyers: 1)
    flags = [flag("new_customer_drop_vs_avg4", "new_customer", "high"), flag("product_stockout_risk", "product_inventory", "high")]

    result = WeeklyHeadlineClassifier.call(period: @period, metrics: metrics, risk_flags: flags, business_signals: [])
    assert_equal "活動後回落／新客不足警戒週", result["display"]
  end

  test "falls back to insufficient-data warning when at least two areas are gray" do
    signals = [{ "status" => "gray" }, { "status" => "gray" }, { "status" => "green" }]
    result = WeeklyHeadlineClassifier.call(period: @period, metrics: metrics, risk_flags: [], business_signals: signals)
    assert_equal "資料不足待確認週", result["labels"].last
  end
end

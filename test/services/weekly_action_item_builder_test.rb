# frozen_string_literal: true

require "test_helper"

class WeeklyActionItemBuilderTest < ActiveSupport::TestCase
  setup do
    @period = WeeklyPeriod.new(Date.new(2026, 9, 7))
  end

  def flag(key, category, severity, evidence = {})
    { key: key, category: category, severity: severity, evidence: evidence }
  end

  test "every high-severity flag becomes a P0 item with a concrete action and success metric" do
    flags = [flag("new_customer_drop_vs_avg4", "new_customer", "high", { "current" => 5, "trailing4_weekly_avg" => 17, "drop_pct" => 70.6 })]
    items = WeeklyActionItemBuilder.call(period: @period, risk_flags: flags)

    assert_equal 1, items.size
    item = items.first
    assert_equal "P0", item[:priority]
    assert_not item[:action].include?("持續觀察")
    assert_not item[:action].include?("加強行銷")
    assert item[:success_metric].present?
    assert item[:suggested_owner_role].present?
  end

  test "medium severity maps to P1 and low/data_anomaly maps to P2" do
    flags = [flag("returning_aov_drop_vs_avg4", "old_customer", "medium"), flag("new_customer_aov_up_but_count_down", "new_customer", "low")]
    items = WeeklyActionItemBuilder.call(period: @period, risk_flags: flags)

    assert_equal "P1", items.find { |i| i[:priority] != "P2" }[:priority]
    assert_includes items.map { |i| i[:priority] }, "P2"
  end

  test "caps at 5 items but always includes every red flag even when reds alone reach the cap" do
    reds = (1..6).map { |i| flag("k#{i}", "revenue", "high") }
    items = WeeklyActionItemBuilder.call(period: @period, risk_flags: reds)

    assert_equal 6, items.size
    assert items.all? { |i| i[:priority] == "P0" }
  end

  test "sorts P0 before P1 before P2 and stops at 5 when reds do not fill the list alone" do
    flags = [
      flag("a", "revenue", "medium"), flag("b", "revenue", "medium"), flag("c", "revenue", "medium"),
      flag("d", "revenue", "low"), flag("e", "revenue", "low"),
      flag("f", "new_customer", "high")
    ]
    items = WeeklyActionItemBuilder.call(period: @period, risk_flags: flags)

    assert_equal 5, items.size
    assert_equal "P0", items.first[:priority]
    assert_equal %w[P0 P1 P1 P1 P2], items.map { |i| i[:priority] }
  end

  test "due dates are staggered by priority relative to the report period" do
    flags = [flag("x", "revenue", "high"), flag("y", "revenue", "medium"), flag("z", "revenue", "low")]
    items = WeeklyActionItemBuilder.call(period: @period, risk_flags: flags)

    p0 = items.find { |i| i[:priority] == "P0" }
    p1 = items.find { |i| i[:priority] == "P1" }
    p2 = items.find { |i| i[:priority] == "P2" }
    assert_equal (@period.week_end + 7).to_s, p0[:due_date]
    assert_equal (@period.week_end + 10).to_s, p1[:due_date]
    assert_equal (@period.week_end + 14).to_s, p2[:due_date]
  end

  test "data_quality flags use the explicit 完成資料確認 action allowed by spec, with no investigation directions" do
    flags = [flag("product_cycle_cache_stale", "data_quality", "data_anomaly", { "product_keys" => ["x"] })]
    item = WeeklyActionItemBuilder.call(period: @period, risk_flags: flags).first

    assert_includes item[:action], "完成資料確認"
    assert_equal [], item[:investigation_directions]
  end

  test "product stockout risk item references the specific product and its trigger reasons" do
    flags = [flag("product_stockout_risk", "product_inventory", "high",
                   { "label" => "全能", "reasons" => ["歷史回購率56.9%（≥40%）"] })]
    item = WeeklyActionItemBuilder.call(period: @period, risk_flags: flags).first

    assert_includes item[:problem], "全能"
    assert_includes item[:action], "全能"
    assert_equal WeeklyInvestigationDirections.for("product_inventory"), item[:investigation_directions]
  end

  test "returns an empty list when there are no risk flags" do
    assert_equal [], WeeklyActionItemBuilder.call(period: @period, risk_flags: [])
  end
end

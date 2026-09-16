# frozen_string_literal: true

require "test_helper"

class WeeklyBusinessSignalClassifierTest < ActiveSupport::TestCase
  def base_metrics
    {
      "revenue_progress" => { "this_week_revenue" => 994_634.0, "comparable_basis" => { "basis_label" => "近4個一般自然週平均", "growth_pct" => 5.0 } },
      "new_vs_returning" => {
        "this_week" => { "new_customers" => 20, "returning_customers" => 80 },
        "trailing4_weekly_avg" => { "new_customers" => 20.0, "returning_customers" => 80.0 }
      },
      "product_repurchase" => { "products" => [{ "product_key" => "x", "label" => "測試品", "availability_status" => "in_stock" }] }
    }
  end

  def flag(key, category, severity)
    { key: key, category: category, severity: severity, evidence: {} }
  end

  test "an area with no flags in its category is green" do
    signals = WeeklyBusinessSignalClassifier.call(base_metrics, [])["signals"]
    assert signals.all? { |s| s["status"] == "green" }
  end

  test "an area with a high-severity flag in its category is red, medium is yellow" do
    flags = [flag("new_customer_drop_vs_avg4", "new_customer", "high"), flag("returning_aov_drop_vs_avg4", "old_customer", "medium")]
    signals = WeeklyBusinessSignalClassifier.call(base_metrics, flags)["signals"]

    assert_equal "red", signals.find { |s| s["area"] == "new_customer" }["status"]
    assert_equal "yellow", signals.find { |s| s["area"] == "old_customer" }["status"]
    assert_equal "green", signals.find { |s| s["area"] == "revenue" }["status"]
  end

  test "gray takes priority over flags when there is no comparable baseline" do
    m = base_metrics
    m["revenue_progress"]["comparable_basis"] = { "growth_pct" => nil }
    signals = WeeklyBusinessSignalClassifier.call(m, [flag("revenue_comparable_basis_drop", "revenue", "high")])["signals"]

    assert_equal "gray", signals.find { |s| s["area"] == "revenue" }["status"]
  end

  test "gray areas are excluded from can_be_used_for and listed in cannot_be_used_for" do
    m = base_metrics
    m["product_repurchase"]["products"] = []
    result = WeeklyBusinessSignalClassifier.call(m, [])

    assert_not result["can_be_used_for"].any? { |s| s.include?("商品與庫存") }
    assert result["cannot_be_used_for"].any? { |s| s.include?("商品與庫存") }
  end

  test "recommended_direction pulls from the shared investigation-direction dictionary when not green" do
    flags = [flag("new_customer_drop_vs_avg4", "new_customer", "high")]
    signal = WeeklyBusinessSignalClassifier.call(base_metrics, flags)["signals"].find { |s| s["area"] == "new_customer" }

    assert_match(/廣告曝光/, signal["recommended_direction"])
  end
end

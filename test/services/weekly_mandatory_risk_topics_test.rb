# frozen_string_literal: true

require "test_helper"

class WeeklyMandatoryRiskTopicsTest < ActiveSupport::TestCase
  def flag(key, category, severity, evidence = {})
    { key: key, category: category, severity: severity, evidence: evidence }
  end

  test "returns no mandatory topics when there are no high-severity flags" do
    topics = WeeklyMandatoryRiskTopics.call([flag("new_customer_pct_too_low", "new_customer", "medium")])
    assert_empty topics
  end

  test "a single high flag in the top tier becomes the sole mandatory topic" do
    topics = WeeklyMandatoryRiskTopics.call([flag("new_customer_drop_vs_avg4", "new_customer", "high")])
    assert_equal 1, topics.size
    assert_equal "new_customer_drop_vs_avg4", topics.first["topic_key"]
  end

  test "new_customer and product_inventory high flags tie for the top tier and both become mandatory (compound risk)" do
    flags = [
      flag("new_customer_drop_vs_avg4", "new_customer", "high"),
      flag("product_stockout_risk", "product_inventory", "high", { label: "全能" }),
      flag("returning_customer_drop_vs_avg4", "old_customer", "high"),
      flag("revenue_comparable_basis_drop", "revenue", "high")
    ]
    topics = WeeklyMandatoryRiskTopics.call(flags)

    assert_equal 2, topics.size
    assert_equal %w[new_customer_drop_vs_avg4 product_stockout_risk].sort, topics.map { |t| t["topic_key"] }.sort
    assert_equal "全能缺貨", topics.find { |t| t["topic_key"] == "product_stockout_risk" }["label"]
  end

  test "revenue only becomes mandatory when the top tier (new_customer/product_inventory) has no high flags" do
    flags = [flag("revenue_comparable_basis_drop", "revenue", "high"), flag("returning_customer_drop_vs_avg4", "old_customer", "high")]
    topics = WeeklyMandatoryRiskTopics.call(flags)

    assert_equal 1, topics.size
    assert_equal "revenue_comparable_basis_drop", topics.first["topic_key"]
  end

  test "old_customer only becomes mandatory when neither the top tier nor revenue has a high flag" do
    topics = WeeklyMandatoryRiskTopics.call([flag("returning_customer_drop_vs_avg4", "old_customer", "high")])
    assert_equal 1, topics.size
    assert_equal "returning_customer_drop_vs_avg4", topics.first["topic_key"]
  end

  test "medium-severity flags in the top tier are excluded when a high flag exists elsewhere in that tier" do
    flags = [flag("new_customer_drop_vs_avg4", "new_customer", "high"), flag("new_customer_pct_too_low", "new_customer", "medium")]
    topics = WeeklyMandatoryRiskTopics.call(flags)

    assert_equal 1, topics.size
    assert_equal "new_customer_drop_vs_avg4", topics.first["topic_key"]
  end
end

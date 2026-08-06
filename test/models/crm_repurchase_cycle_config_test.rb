# frozen_string_literal: true

require "test_helper"

class CrmRepurchaseCycleConfigTest < ActiveSupport::TestCase
  def unique_key
    "test_product_#{SecureRandom.hex(4)}"
  end

  test "uniqueness on product_key + bottle_count" do
    key = unique_key
    CrmRepurchaseCycleConfig.create!(product_key: key, bottle_count: 1, median_days: 30, source: "manual")

    dup = CrmRepurchaseCycleConfig.new(product_key: key, bottle_count: 1, median_days: 45, source: "manual")
    assert_not dup.valid?
  end

  test "requires positive median_days and bottle_count" do
    config = CrmRepurchaseCycleConfig.new(product_key: unique_key, bottle_count: 0, median_days: 0, source: "manual")
    assert_not config.valid?
    assert config.errors[:bottle_count].present?
    assert config.errors[:median_days].present?
  end

  test "expected_days returns nil when no config exists for the product" do
    assert_nil CrmRepurchaseCycleConfig.expected_days(unique_key, 3)
  end

  test "expected_days returns exact match when bottle_count bucket exists" do
    key = unique_key
    CrmRepurchaseCycleConfig.create!(product_key: key, bottle_count: 2, median_days: 60, source: "manual")

    assert_equal 60, CrmRepurchaseCycleConfig.expected_days(key, 2)
  end

  test "expected_days interpolates linearly between two known buckets" do
    key = unique_key
    CrmRepurchaseCycleConfig.create!(product_key: key, bottle_count: 1, median_days: 30, source: "manual")
    CrmRepurchaseCycleConfig.create!(product_key: key, bottle_count: 3, median_days: 90, source: "manual")

    assert_equal 60, CrmRepurchaseCycleConfig.expected_days(key, 2)
  end

  test "expected_days falls back to nearest known bucket outside the known range" do
    key = unique_key
    CrmRepurchaseCycleConfig.create!(product_key: key, bottle_count: 2, median_days: 60, source: "manual")
    CrmRepurchaseCycleConfig.create!(product_key: key, bottle_count: 4, median_days: 100, source: "manual")

    assert_equal 60,  CrmRepurchaseCycleConfig.expected_days(key, 1)
    assert_equal 100, CrmRepurchaseCycleConfig.expected_days(key, 10)
  end

  test "addon_window_days is 30% of expected_days, rounded" do
    assert_equal 18, CrmRepurchaseCycleConfig.addon_window_days(60)  # 60*0.3 = 18
    assert_equal 15, CrmRepurchaseCycleConfig.addon_window_days(50)  # 50*0.3 = 15
  end

  test "addon_window_days floors at ADDON_WINDOW_MIN_DAYS for very short cycles" do
    assert_equal 3, CrmRepurchaseCycleConfig.addon_window_days(5)   # 5*0.3 = 1.5 -> floored to 3
    assert_equal 3, CrmRepurchaseCycleConfig.addon_window_days(1)
  end

  test "addon_window_days boundary: exactly at min days threshold" do
    # 10*0.3 = 3.0，剛好等於下限，不應該再被 floor 邏輯改變
    assert_equal 3, CrmRepurchaseCycleConfig.addon_window_days(10)
  end
end

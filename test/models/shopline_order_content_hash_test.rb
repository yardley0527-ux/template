# frozen_string_literal: true

require "test_helper"

class ShoplineOrderContentHashTest < ActiveSupport::TestCase
  def hash_for(order_number: "#A1", product_name: "清纖粉2", quantity: 1,
              checkout_amount: 2980, occurrence: 1)
    ShoplineOrder.content_hash(order_number: order_number, product_name: product_name,
                               quantity: quantity, checkout_amount: checkout_amount,
                               occurrence: occurrence)
  end

  test "total_amount is not part of the signature (no such parameter exists anymore)" do
    assert_not ShoplineOrder.method(:content_hash).parameters.map(&:last).include?(:total_amount)
  end

  test "checkout_amount formatting differences normalize to the same hash" do
    plain  = hash_for(checkout_amount: 2980)
    float  = hash_for(checkout_amount: 2980.0)
    comma  = hash_for(checkout_amount: "2,980")
    padded = hash_for(checkout_amount: " 2980 ")

    assert_equal plain, float
    assert_equal plain, comma
    assert_equal plain, padded
  end

  test "quantity formatting differences normalize to the same hash" do
    assert_equal hash_for(quantity: 2), hash_for(quantity: "2")
    assert_equal hash_for(quantity: 2), hash_for(quantity: 2.0)
  end

  test "whitespace-only product_name differences normalize to the same hash" do
    assert_equal hash_for(product_name: "清纖粉2"), hash_for(product_name: " 清纖粉2 ")
    assert_equal hash_for(product_name: "清纖粉2"), hash_for(product_name: "清纖粉2  ")
  end

  test "genuinely different product_name never collapses to the same hash" do
    assert_not_equal hash_for(product_name: "清纖粉2"), hash_for(product_name: "清纖粉3")
    assert_not_equal hash_for(product_name: "清纖粉2"), hash_for(product_name: "清纖粉2送1")
  end

  test "different order_number never collapses even with identical content" do
    assert_not_equal hash_for(order_number: "#A1"), hash_for(order_number: "#A2")
  end

  test "occurrence disambiguates identical lines within the same order" do
    first  = hash_for(order_number: "#A1", occurrence: 1)
    second = hash_for(order_number: "#A1", occurrence: 2)

    assert_not_equal first, second
  end

  test "nil checkout_amount hashes stably as blank, not as an error" do
    assert_nothing_raised { hash_for(checkout_amount: nil) }
    assert_equal hash_for(checkout_amount: nil), hash_for(checkout_amount: nil)
  end

  test "format_decimal handles thousands separators and blank input" do
    assert_equal ShoplineOrder.format_decimal(2980), ShoplineOrder.format_decimal("2,980")
    assert_equal ShoplineOrder.format_decimal(2980), ShoplineOrder.format_decimal(" 2980 ")
    assert_equal "", ShoplineOrder.format_decimal(nil)
    assert_equal "", ShoplineOrder.format_decimal("")
  end

  test "normalize_product_name only touches whitespace" do
    assert_equal "代謝錠1薑黃1送清纖粉1", ShoplineOrder.normalize_product_name("代謝錠1薑黃1送清纖粉1")
    assert_equal "清纖粉2", ShoplineOrder.normalize_product_name("  清纖粉2  ")
    assert_equal "清 纖 粉", ShoplineOrder.normalize_product_name("清   纖 粉")
  end
end

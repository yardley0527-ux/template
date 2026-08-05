# frozen_string_literal: true

require "test_helper"

class RepurchaseCycleMedianCalculatorTest < ActiveSupport::TestCase
  def unique_key
    "med_calc_#{SecureRandom.hex(4)}"
  end

  def make_product(key, label)
    CrmProduct.create!(key: key, label: label, status: "confirmed",
                        sql_pattern: "product_name LIKE '%#{label}%'", regex_pattern: "#{label}(\\d+)")
  end

  def make_order(email:, product_name:, order_date:, payment_status: "已付款")
    ShoplineOrder.create!(
      order_number: "ORD#{SecureRandom.hex(6)}", email: email, product_name: product_name,
      order_date: order_date, payment_status: payment_status, quantity: 1
    )
  end

  test "ignores refunded, unpaid and blank-field orders" do
    key = unique_key
    make_product(key, "測試品甲")
    email = "buyer_#{SecureRandom.hex(4)}@example.com"

    make_order(email: email, product_name: "測試品甲1", order_date: Date.new(2026, 1, 1))
    make_order(email: email, product_name: "測試品甲1", order_date: Date.new(2026, 2, 1), payment_status: "未付款")
    make_order(email: email, product_name: "測試品甲1", order_date: Date.new(2026, 2, 15), payment_status: "已退款")
    make_order(email: email, product_name: "測試品甲1", order_date: Date.new(2026, 3, 3))

    5.times do |i|
      other = "buyer_#{SecureRandom.hex(4)}@example.com"
      make_order(email: other, product_name: "測試品甲1", order_date: Date.new(2026, 1, 1) + i)
      make_order(email: other, product_name: "測試品甲1", order_date: Date.new(2026, 1, 1) + i + 61)
    end

    result = RepurchaseCycleMedianCalculator.call(product_key: key)
    # 只有已付款訂單間隔（1/1 -> 3/3 = 61 天）應該被算進去，不是未付款/已退款那兩筆製造出來的短間隔
    assert_equal 61, result[1][:median_days]
  end

  test "buckets intervals by the starting purchase's bottle count" do
    key = unique_key
    make_product(key, "測試品乙")

    6.times do |i|
      email = "b_#{SecureRandom.hex(4)}@example.com"
      make_order(email: email, product_name: "測試品乙2", order_date: Date.new(2026, 1, 1))
      make_order(email: email, product_name: "測試品乙2", order_date: Date.new(2026, 1, 1) + 60 + i)
    end

    result = RepurchaseCycleMedianCalculator.call(product_key: key)
    assert_nil result[1]
    assert_equal 6, result[2][:sample_size]
    assert_equal (60..65).to_a[3], result[2][:median_days] # median of 60..65
  end

  test "buckets below MIN_SAMPLE_SIZE are excluded" do
    key = unique_key
    make_product(key, "測試品丙")
    email = "solo_#{SecureRandom.hex(4)}@example.com"
    make_order(email: email, product_name: "測試品丙1", order_date: Date.new(2026, 1, 1))
    make_order(email: email, product_name: "測試品丙1", order_date: Date.new(2026, 2, 1))

    result = RepurchaseCycleMedianCalculator.call(product_key: key)
    assert_equal({}, result)
  end

  test "identity_key merges same customer across different emails via mobile_phone" do
    key = unique_key
    make_product(key, "測試品丁")

    5.times do |i|
      email_a = "a_#{SecureRandom.hex(4)}@example.com"
      email_b = "b_#{SecureRandom.hex(4)}@example.com"
      shared_phone = format("09%08d", rand(100_000_000))
      ShoplineCustomer.create!(email: email_a, mobile_phone: shared_phone, full_name: "測試客#{i}")
      ShoplineCustomer.create!(email: email_b, mobile_phone: shared_phone, full_name: "測試客#{i}")

      make_order(email: email_a, product_name: "測試品丁1", order_date: Date.new(2026, 1, 1))
      # 同一支手機、不同 email 的下一筆訂單，應該被視為同一人的回購間隔
      make_order(email: email_b, product_name: "測試品丁1", order_date: Date.new(2026, 1, 1) + 40)
    end

    result = RepurchaseCycleMedianCalculator.call(product_key: key)
    assert_equal 5, result[1][:sample_size]
    assert_equal 40, result[1][:median_days]
  end
end

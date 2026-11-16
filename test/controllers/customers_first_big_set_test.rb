# frozen_string_literal: true

require "test_helper"

# 客人資料庫：首購大組數（首購產品付費 ≥ 10 瓶）標籤與篩選
class CustomersFirstBigSetTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  def order(num, date, email, product, price, qty: 1)
    ShoplineOrder.create!(order_number: num, order_date: date, email: email, product_name: product,
                          quantity: qty, checkout_amount: price, total_amount: price, payment_status: "已付款")
  end

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    sign_in User.create!(email: "bs_owner@test.com", username: "bs_owner", password: "password123", role: admin_role)

    ShoplineCustomer.create!(email: "big@example.com", full_name: "大組數甲")
    order("#b1", Date.new(2026, 10, 1), "big@example.com", "預購-PDRN10", 19_800)

    ShoplineCustomer.create!(email: "gift@example.com", full_name: "送的不算乙")
    order("#g1", Date.new(2026, 5, 1), "gift@example.com", "代謝錠6送4", 7_000)
    order("#g1", Date.new(2026, 5, 1), "gift@example.com", "代謝錠1", 0)

    ShoplineCustomer.create!(email: "qty@example.com", full_name: "數量丙")
    order("#q1", Date.new(2026, 6, 1), "qty@example.com", "全能5", 9_000, qty: 2)

    CustomerPurchaseSummaryRefreshService.call
  end

  test "首購瓶數：品名數字×數量，送的不算" do
    bottles = CustomerPurchaseSummary.pluck(:email, :first_bottles).to_h
    assert_equal 10, bottles["big@example.com"]
    assert_equal 6, bottles["gift@example.com"]
    assert_equal 10, bottles["qty@example.com"]
  end

  test "客人資料庫顯示大組數標籤並可篩選" do
    get customers_path
    assert_response :success
    assert_select ".badge-big-set", text: "大組數 10 瓶", count: 2

    get customers_path(first_big_set: "1")
    assert_includes response.body, "大組數甲"
    assert_includes response.body, "數量丙"
    assert_not_includes response.body, "送的不算乙"
  end

  test "破萬新客：總額只在其中一行也要判斷到" do
    ShoplineCustomer.create!(email: "split@example.com", full_name: "多行丁")
    ShoplineOrder.create!(order_number: "#s1", order_date: Date.new(2024, 3, 30), email: "split@example.com", product_name: "薑黃1",
                          quantity: 1, checkout_amount: 1_200, total_amount: nil, payment_status: "已付款")
    ShoplineOrder.create!(order_number: "#s1", order_date: Date.new(2024, 3, 30), email: "split@example.com", product_name: "代謝錠6薑黃9",
                          quantity: 1, checkout_amount: 24_680, total_amount: 25_880, payment_status: "已付款")
    CustomerPurchaseSummaryRefreshService.call

    get customers_path(big_first: "1")
    assert_includes response.body, "多行丁"
    assert_includes response.body, "大組數甲"
    assert_not_includes response.body, "送的不算乙"
  end

  test "營運追蹤名單的破萬新客欄與篩選" do
    c = ShoplineCustomer.find_by!(email: "big@example.com")
    c.create_customer_profile!(tracked: true)
    get tracked_customers_path
    assert_response :success
    assert_includes response.body, "✅ 10/01"
    get tracked_customers_path(big_first: "1")
    assert_response :success
    assert_includes response.body, "大組數甲"
  end
end

# frozen_string_literal: true

require "test_helper"

class PdrnPreorderTrackingControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  def order(num, date, email, product, price, total: nil, ig: nil, level: nil)
    ShoplineOrder.create!(order_number: num, order_date: date, email: email, instagram_account: ig, product_name: product,
                          quantity: 1, checkout_amount: price, total_amount: total, payment_status: "已付款", membership_level: level)
  end

  setup do
    Rails.cache.clear
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    sign_in User.create!(email: "pp_owner@test.com", username: "pp_owner", password: "password123", role: admin_role)

    # 新客：預購是首購，之後用另一個 email（同 IG）買瘦身組合
    ShoplineCustomer.create!(email: "new@example.com", full_name: "預購新客", instagram_account: "new_ig", membership_level: "白卡")
    order("#1", Date.new(2026, 10, 1), "new@example.com", "預購-PDRN10", 19_800, total: 19_800, ig: "new_ig")
    order("#2", Date.new(2026, 11, 15), "new2@example.com", "肉鹼1代謝錠1薑黃1清纖粉1", 7_365, total: 7_365, ig: "new_ig")

    # 舊客：之前買過全能，預購後沒再買
    ShoplineCustomer.create!(email: "old@example.com", full_name: "預購舊客", membership_level: "銀卡")
    order("#3", Date.new(2026, 5, 1), "old@example.com", "全能3", 4_500, total: 4_500, level: "銀卡")
    order("#4", Date.new(2026, 10, 5), "old@example.com", "預購-PDRN1", 2_750, total: 2_750, level: "銀卡")

    # 黑名單：排除
    bl = ShoplineCustomer.create!(email: "bl@example.com", full_name: "黑名單客")
    bl.create_customer_profile!(blacklisted: true)
    order("#5", Date.new(2026, 10, 6), "bl@example.com", "預購-PDRN5", 10_800, total: 10_800)
  end

  test "列出預購客、合併同 IG、排除黑名單" do
    get pdrn_preorder_tracking_path
    assert_response :success
    assert_includes response.body, "預購新客"
    assert_includes response.body, "預購舊客"
    assert_not_includes response.body, ">黑名單客<"
    assert_includes response.body, "已排除黑名單 1 人（黑名單客）"
    assert_select ".pp-tag.pp-new", text: "預購是首購"
    assert_select ".pp-tag", text: "瘦身組合"
    assert_select ".pp-up", text: "白" # 一般會員 → 白卡
  end

  test "篩選預購後有再買" do
    get pdrn_preorder_tracking_path(status: "repurchased")
    assert_includes response.body, "預購新客"
    assert_not_includes response.body, "預購舊客"
  end

  test "摘要數字" do
    data = PdrnPreorderTracking.new.call
    s = data[:summary]
    assert_equal 2, s[:total]
    assert_equal 1, s[:new_customers]
    assert_equal 1, s[:repurchased]
    assert_equal 1, s[:upgraded]
    new_person = data[:people].find { |p| p[:name] == "預購新客" }
    assert_equal 10, new_person[:pre_bottles]
    assert_equal 7_365, new_person[:after_amount]
  end
end

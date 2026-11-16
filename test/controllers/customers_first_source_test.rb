# frozen_string_literal: true

require "test_helper"

class CustomersFirstSourceTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    sign_in User.create!(email: "fs_owner@test.com", username: "fs_owner", password: "password123", role: admin_role)

    ShoplineCustomer.create!(email: "pre@example.com", full_name: "預購甲客", mobile_phone: "0911000111")
    ShoplineCustomer.create!(email: "omni@example.com", full_name: "全能客")
    CustomerPurchaseSummary.create!(identity_key: "0911000111", email: "pre@example.com", first_series: "PDRN",
                                    first_product: "預購-PDRN10", first_date: Time.zone.local(2026, 10, 27))
    CustomerPurchaseSummary.create!(identity_key: "omni@example.com", email: "omni@example.com", first_series: "全能",
                                    first_product: "全能3", first_date: Time.zone.local(2026, 3, 1))
  end

  test "列表顯示首購來源，PDRN 拆出預購" do
    get customers_path
    assert_response :success
    assert_includes response.body, "首購來源"
    assert_select "span.badge-first-source.badge-first-preorder", text: "PDRN 預購"
    assert_select "span.badge-first-source", text: "全能"
  end

  test "可以用首購來源篩選" do
    get customers_path(first_source: "PDRN 預購")
    assert_response :success
    assert_includes response.body, "預購甲客"
    assert_not_includes response.body, "全能客"

    get customers_path(first_source: "全能")
    assert_includes response.body, "全能客"
    assert_not_includes response.body, "預購甲客"
  end

  test "客人頁顯示首購產品" do
    get customer_path(ShoplineCustomer.find_by(email: "pre@example.com"))
    assert_response :success
    assert_select ".stat-label", text: "首購產品"
    assert_select ".stat-value.first-source.preorder", text: "PDRN 預購"
    assert_includes response.body, "預購-PDRN10・2026/10/27"
  end
end

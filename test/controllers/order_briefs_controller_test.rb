# frozen_string_literal: true

require "test_helper"

class OrderBriefsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    sign_in User.create!(email: "brief-admin@test.com", username: "brief_admin", password: "password123", role: admin_role)
    ShoplineCustomer.create!(email: "amy@example.com", full_name: "Amy", membership_level: "金卡")
    [["#A1", Date.new(2026, 6, 1), "全能2"], ["#A2", Date.new(2026, 10, 22), "全能3"]].each do |number, date, item|
      ShoplineOrder.create!(order_number: number, email: "amy@example.com", product_name: item, quantity: 1,
                            total_amount: 5000, payment_status: "已付款", order_date: Time.utc(date.year, date.month, date.day))
    end
  end

  test "明細頁列出回購客人" do
    get order_briefs_path(date: "2026-10-22")
    assert_response :ok
    assert_includes response.body, "每日訂單簡報 10/22（四）"
    assert_includes response.body, "回購 全能（1 人）"
    assert_includes response.body, "Amy"
    assert_includes response.body, "143 天"
  end

  test "沒有訂單的日子顯示提示" do
    get order_briefs_path(date: "2026-10-01")
    assert_response :ok
    assert_includes response.body, "這天沒有已付款訂單"
  end
end

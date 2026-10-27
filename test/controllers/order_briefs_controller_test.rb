# frozen_string_literal: true

require "test_helper"

class OrderBriefsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  DAY = Date.new(2026, 10, 22)

  setup do
    @old_ai = ENV.delete("ANTHROPIC_API_KEY") # 不打真的 AI
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    @admin = User.create!(email: "brief-admin@test.com", username: "brief_admin", password: "password123", role: admin_role)
    ShoplineCustomer.create!(email: "amy@example.com", full_name: "Amy", membership_level: "黑卡")
    ShoplineOrder.create!(order_number: "#A1", email: "amy@example.com", product_name: "PDRN3", quantity: 1, total_amount: 9000,
                          checkout_amount: 9000, payment_status: "已付款", order_date: Time.zone.local(2026, 9, 20, 12))
    ShoplineOrder.create!(order_number: "#A2", email: "amy@example.com", product_name: "PDRN6", quantity: 1, total_amount: 20_000,
                          checkout_amount: 20_000, payment_status: "已付款", order_date: Time.zone.local(2026, 10, 22, 12))
  end

  teardown { ENV["ANTHROPIC_API_KEY"] = @old_ai if @old_ai }

  test "第一次進來只有表單，選日期才產生；文字有複製按鈕、表格直接畫在網頁上" do
    sign_in @admin
    get order_briefs_path
    assert_response :ok
    assert_includes response.body, "產生簡報"
    assert_not_includes response.body, "訂單簡報\n"

    get order_briefs_path, params: { date: DAY.iso8601, ai: "1" }
    assert_response :ok
    assert_includes response.body, "10/22 訂單簡報"
    assert_includes response.body, "複製"
    assert_includes response.body, "回購 PDRN"
    assert_includes response.body, "Amy"
  end

  test "產生銷售日報：每段可複製，也可以全部複製" do
    sign_in @admin
    get order_briefs_path, params: { date: DAY.iso8601, report: "sales" }
    assert_response :ok
    assert_includes response.body, "10/22 銷售日報"
    assert_includes response.body, "全部複製"
    assert_includes response.body, "SL 訂單"
    assert_includes response.body, "月累計"
    assert_not_includes response.body, "回購 PDRN" # 不是訂單簡報
  end

  test "那天沒有訂單就說沒有" do
    sign_in @admin
    get order_briefs_path, params: { date: "2026-10-01" }
    assert_includes response.body, "10/1 沒有已付款訂單"
  end
end

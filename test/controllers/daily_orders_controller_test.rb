# frozen_string_literal: true

require "test_helper"

class DailyOrdersControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    data_role  = Role.find_or_create_by!(key: "data") { |r| r.name = "數據部" }
    PagePermission.find_or_create_by!(role: data_role, controller_name: "daily_orders")

    @owner = User.create!(email: "owner_test@test.com", username: "owner_test", password: "password123", role: admin_role)
    @data  = User.create!(email: "data_test@test.com", username: "data_test", password: "password123", role: data_role)

    @customer = ShoplineCustomer.create!(email: "skip-test@example.com")
  end

  test "只有 owner（admin）能勾選略過訊息" do
    sign_in @owner
    post toggle_daily_orders_customer_flag_path, params: {
      customer_id: @customer.id, field: "skip_follow_up", value: "true", page: "daily_orders"
    }
    assert_response :success
    assert @customer.reload.customer_profile.skip_follow_up
  end

  test "非 owner（即使有頁面權限）勾略過訊息也會被擋" do
    sign_in @data
    post toggle_daily_orders_customer_flag_path, params: {
      customer_id: @customer.id, field: "skip_follow_up", value: "true", page: "daily_orders"
    }
    assert_response :forbidden
    assert_not @customer.reload.customer_profile&.skip_follow_up
  end
  test "黑名單客人的訂單標示不要傳訊（email 或同 IG 都算）" do
    day = Date.new(2026, 11, 9)
    bl = ShoplineCustomer.create!(email: "bl@example.com", full_name: "黑名單客", instagram_account: "bl_ig_test")
    bl.create_customer_profile!(blacklisted: true)
    ShoplineCustomer.create!(email: "ok@example.com", full_name: "一般客")
    ShoplineOrder.create!(order_number: "BL1", email: "bl@example.com", customer_name: "黑名單客", product_name: "薑黃1", quantity: 1, total_amount: 1000, payment_status: "已付款", order_date: day.noon, source_row_hash: "bl1")
    ShoplineOrder.create!(order_number: "BL2", email: "other@example.com", customer_name: "分身帳號", instagram_account: "@BL_IG_test", product_name: "薑黃1", quantity: 1, total_amount: 900, payment_status: "已付款", order_date: day.noon, source_row_hash: "bl2")
    ShoplineOrder.create!(order_number: "OK1", email: "ok@example.com", customer_name: "一般客", product_name: "薑黃1", quantity: 1, total_amount: 800, payment_status: "已付款", order_date: day.noon, source_row_hash: "ok1")

    sign_in @owner
    get daily_orders_path(start_date: day.to_s, tab: "new")
    assert_response :success
    assert_select "tr", text: /黑名單客/ do
      assert_select "span.badge", text: "不要傳訊"
    end
    assert_select "tr", text: /分身帳號/ do
      assert_select "span.badge", text: "不要傳訊"
    end
    assert_select "tr", text: /一般客/ do
      assert_select "span.badge", text: "不要傳訊", count: 0
    end
  end
end

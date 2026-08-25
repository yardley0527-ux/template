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
end

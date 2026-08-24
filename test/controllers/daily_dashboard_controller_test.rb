# frozen_string_literal: true

require "test_helper"

class DailyDashboardControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.create!(key: "admin", name: "Admin")
    @admin = User.create!(email: "dd_admin@test.com", username: "dd_admin", password: "password123", role: admin_role)
  end

  test "product breakdown does not double-count an order whose product_name drifted across import runs" do
    old_run = ImportRun.create!(kind: "paid_orders_workbook", file_name: "old.csv", file_checksum: SecureRandom.hex(8))
    new_run = ImportRun.create!(kind: "paid_orders_workbook", file_name: "new.csv", file_checksum: SecureRandom.hex(8))
    date = Time.zone.yesterday.noon

    # total_amount populated on both rows, matching real Shopline exports —
    # production has zero content-drift pairs where both rows lack it.
    ShoplineOrder.create!(order_number: "#DD1", product_name: "薑黃6", payment_status: "已付款",
                          quantity: 1, checkout_amount: 10500, total_amount: 10500, order_date: date,
                          email: "dd1@example.com", source_year: date.year, source_month: date.month,
                          import_run_id: old_run.id, source_row_hash: SecureRandom.hex(8))
    ShoplineOrder.create!(order_number: "#DD1", product_name: "薑黃6送1", payment_status: "已付款",
                          quantity: 1, checkout_amount: 10500, total_amount: 10500, order_date: date,
                          email: "dd1@example.com", source_year: date.year, source_month: date.month,
                          import_run_id: new_run.id, source_row_hash: SecureRandom.hex(8))

    sign_in @admin
    get daily_dashboard_path(start_date: date.to_date, end_date: date.to_date)

    assert_response :success
    assert_includes response.body, "NT$10,500", "the drifted order must be counted once"
    assert_not_includes response.body, "NT$21,000", "counting both product_name variants would double this order's amount"
  end
end

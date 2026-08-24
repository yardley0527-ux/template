# frozen_string_literal: true

require "test_helper"

class CanceledOrderCandidatesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.create!(key: "admin", name: "Admin")
    @admin = User.create!(email: "coc_admin@test.com", username: "coc_admin", password: "password123", role: admin_role)

    staff_role = Role.create!(key: "coc_staff", name: "Staff")
    PagePermission.create!(role: staff_role, controller_name: "canceled_order_candidates")
    @staff = User.create!(email: "coc_staff@test.com", username: "coc_staff", password: "password123", role: staff_role)

    old_run = ImportRun.create!(kind: "paid_orders_workbook", file_name: "old.xlsx", file_checksum: SecureRandom.hex(16))
    new_run = ImportRun.create!(kind: "paid_orders_workbook", file_name: "new.xlsx", file_checksum: SecureRandom.hex(16))

    # Stays 已付款 but only touched by the OLD run for 2026/8 -> candidate.
    @candidate = ShoplineOrder.create!(
      order_number: "#TEST0001", customer_name: "測試客人A", product_name: "測試商品",
      payment_status: "已付款", checkout_amount: 100, quantity: 1,
      source_year: 2026, source_month: 8, import_run_id: old_run.id,
      source_row_hash: SecureRandom.hex(16)
    )

    # Touched by the latest run for the same period -> not a candidate.
    ShoplineOrder.create!(
      order_number: "#TEST0002", customer_name: "測試客人B", product_name: "測試商品",
      payment_status: "已付款", checkout_amount: 200, quantity: 1,
      source_year: 2026, source_month: 8, import_run_id: new_run.id,
      source_row_hash: SecureRandom.hex(16)
    )
  end

  test "index 顯示候選名單，不顯示被最新匯入碰過的訂單" do
    sign_in @admin
    get canceled_order_candidates_path(year: 2026, month: 8)

    assert_response :success
    assert_includes response.body, "TEST0001"
    assert_not_includes response.body, "TEST0002"
  end

  test "非 admin 不能刪除" do
    sign_in @staff
    post purge_canceled_order_candidates_path, params: { year: 2026, month: 8 }

    assert_response :forbidden
    assert ShoplineOrder.exists?(@candidate.id)
  end

  test "admin 刪除候選名單會真的刪除資料並排入快取重整" do
    sign_in @admin

    assert_enqueued_jobs 2 do
      assert_difference -> { ShoplineOrder.count }, -1 do
        post purge_canceled_order_candidates_path, params: { year: 2026, month: 8 }
      end
    end

    assert_response :redirect
    assert_not ShoplineOrder.exists?(@candidate.id)
  end
end

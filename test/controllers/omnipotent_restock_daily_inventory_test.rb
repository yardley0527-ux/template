# frozen_string_literal: true

require "test_helper"

# Regression coverage for Section 八 (inventory source annotation): the
# combined "today's to-do" list on /crm/journey must keep generating rows
# exactly as before (still driven by JourneyProducts.in_stock) — crm_products
# is only allowed to add a display badge, never gate whether a row appears.
class OmnipotentRestockDailyInventoryTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.create!(key: "admin", name: "Admin")
    @user = User.create!(email: "crm@test.com", username: "crm_user", password: "password123", role: admin_role)
    sign_in @user
    travel_to Time.zone.local(2026, 7, 21, 12, 0, 0)

    @customer = ShoplineCustomer.create!(email: "a@example.com", full_name: "測試客", membership_level: "一般")
    ShoplineOrder.create!(email: "a@example.com", product_name: "代謝錠1", order_date: 25.days.ago, checkout_amount: 500)
  end

  teardown { travel_back }

  test "a row still appears on the combined list when crm_products has no row for the product (unknown fallback)" do
    get crm_journey_path
    assert_response :success
    assert_includes response.body, "測試客"
    assert_includes response.body, "未確認"
  end

  test "a row still appears on the combined list even when crm_products confirms out_of_stock" do
    CrmProduct.create!(key: "metabolism", label: "代謝錠", status: "confirmed", availability_status: "out_of_stock")

    get crm_journey_path
    assert_response :success
    assert_includes response.body, "測試客", "the list's own generation logic must stay driven by JourneyProducts.in_stock, not crm_products"
    assert_includes response.body, "缺貨"
  end

  test "an in_stock crm_products confirmation shows no extra inventory badge" do
    CrmProduct.create!(key: "metabolism", label: "代謝錠", status: "confirmed", availability_status: "in_stock")

    get crm_journey_path
    assert_response :success
    assert_includes response.body, "測試客"
    assert_not_includes response.body, "title=\"CRM 產品庫存表狀態"
  end
end

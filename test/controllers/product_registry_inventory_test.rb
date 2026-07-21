# frozen_string_literal: true

require "test_helper"

class ProductRegistryInventoryTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.create!(key: "admin", name: "Admin")
    @admin  = User.create!(email: "adm@test.com", username: "boss", password: "password123",
                           role: admin_role)
    @nobody = User.create!(email: "nobody@test.com", username: "nobody", password: "password123")

    @confirmed = CrmProduct.create!(key: "inv_confirmed", label: "正式品", status: "confirmed")
    @candidate = CrmProduct.create!(key: "inv_candidate", label: "候選品", status: "candidate")
  end

  test "legal update saves status, dates, note and audit fields" do
    sign_in @admin
    patch product_registry_inventory_path(@confirmed), params: { crm_product: {
      availability_status: "out_of_stock",
      expected_restock_date: "2026-08-01",
      actual_restock_date: "",
      inventory_note: "供應商延遲"
    } }

    assert_redirected_to product_registry_path
    @confirmed.reload
    assert_equal "out_of_stock", @confirmed.availability_status
    assert_equal Date.new(2026, 8, 1), @confirmed.expected_restock_date
    assert_nil @confirmed.actual_restock_date
    assert_equal "供應商延遲", @confirmed.inventory_note
    assert @confirmed.inventory_status_updated_at.present?
    assert_equal @admin.id, @confirmed.inventory_status_updated_by_id
  end

  test "paper_trail whodunnit records the acting user" do
    sign_in @admin
    patch product_registry_inventory_path(@confirmed), params: { crm_product: {
      availability_status: "in_stock"
    } }

    version = @confirmed.reload.versions.last
    assert version.present?
    assert_equal @admin.id.to_s, version.whodunnit
  end

  test "illegal availability_status is rejected and nothing is saved" do
    sign_in @admin
    patch product_registry_inventory_path(@confirmed), params: { crm_product: {
      availability_status: "sold_out_forever"
    } }

    assert_redirected_to product_registry_path
    assert_match "庫存更新失敗", flash[:alert]
    assert_equal "unknown", @confirmed.reload.availability_status
    assert_nil @confirmed.inventory_status_updated_at
  end

  test "candidate products cannot be updated" do
    sign_in @admin
    patch product_registry_inventory_path(@candidate), params: { crm_product: {
      availability_status: "in_stock"
    } }

    assert_redirected_to product_registry_path
    assert_equal "只有正式產品可以管理庫存", flash[:alert]
    assert_equal "unknown", @candidate.reload.availability_status
  end

  test "user without permission gets forbidden" do
    sign_in @nobody
    patch product_registry_inventory_path(@confirmed), params: { crm_product: {
      availability_status: "in_stock"
    } }

    assert_response :forbidden
    assert_equal "unknown", @confirmed.reload.availability_status
  end

  test "index shows inventory forms only for confirmed products" do
    sign_in @admin
    get product_registry_path

    assert_response :success
    assert_includes response.body, "正式產品庫存"
    assert_includes response.body, product_registry_inventory_path(@confirmed)
    assert_not_includes response.body, product_registry_inventory_path(@candidate)
  end

  test "index does not N+1 query inventory_status_updated_by per product" do
    updater = User.create!(email: "updater@test.com", username: "updater", password: "password123")
    12.times do |i|
      product = CrmProduct.create!(key: "inv_bulk_#{i}", label: "量產品#{i}", status: "confirmed")
      product.update!(availability_status: "in_stock", inventory_status_updated_by_id: updater.id,
                      inventory_status_updated_at: Time.current)
    end

    sign_in @admin
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] if payload[:sql].include?('"users"')
    end
    get product_registry_path
    ActiveSupport::Notifications.unsubscribe(subscriber)

    assert_response :success
    # 14 個 confirmed 產品（2 個 setup + 12 個新建）應該只需要 1 次 users JOIN/IN 查詢，
    # 不是每個產品各查一次。
    assert_operator queries.size, :<=, 1, "expected inventory_status_updated_by to be eager-loaded, got queries: #{queries}"
  end
end

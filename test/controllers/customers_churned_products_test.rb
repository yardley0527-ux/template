# frozen_string_literal: true

require "test_helper"

class CustomersChurnedProductsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    sign_in User.create!(email: "churn_owner@test.com", username: "churn_owner", password: "password123", role: admin_role)
    @customer = ShoplineCustomer.create!(email: "churn@example.com", full_name: "流失測試客")
  end

  test "編輯頁可以勾選流失產品並在客人頁顯示" do
    get edit_customer_path(@customer)
    assert_response :success
    assert_select "#churned-product-selector[style*='display:none'] .product-tag-chip", text: "代謝錠"

    patch customer_path(@customer), params: { customer_profile: { churned: "1", churned_products: ["", "代謝錠", "薑黃"] } }
    profile = @customer.reload.customer_profile
    assert profile.churned?
    assert_equal %w[代謝錠 薑黃], profile.churned_products

    get customer_path(@customer)
    assert_includes response.body, "（代謝錠、薑黃）"

    get edit_customer_path(@customer)
    assert_select "#churned-product-selector[style*='display:none']", count: 0
  end

  test "追蹤打開後可以多選產品，關掉會清空" do
    get edit_customer_path(@customer)
    assert_select "#tracked-product-selector[style*='display:none'] .product-tag-chip", text: "全能"

    patch customer_path(@customer), params: { customer_profile: { tracked: "1", tracked_products: ["", "全能", "PDRN"] } }
    assert_equal %w[全能 PDRN], @customer.reload.customer_profile.tracked_products

    get customer_path(@customer)
    assert_includes response.body, "（全能、PDRN）"

    patch customer_path(@customer), params: { customer_profile: { tracked: "0", tracked_products: ["", "全能"] } }
    assert_equal [], @customer.reload.customer_profile.tracked_products
  end
end

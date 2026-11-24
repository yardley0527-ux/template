# frozen_string_literal: true

require "test_helper"

class CustomersPrGiftFilterTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    sign_in User.create!(email: "pr_owner@test.com", username: "pr_owner", password: "password123", role: admin_role)

    carn = ShoplineCustomer.create!(email: "carn@example.com", full_name: "肉鹼公關客")
    mask = ShoplineCustomer.create!(email: "mask@example.com", full_name: "面膜公關客")
    ShoplineCustomer.create!(email: "none@example.com", full_name: "沒收過客")
    carn.pr_gifts.create!(product_name: "肉鹼", quantity: 1, unit: "盒", given_on: Date.new(2026, 11, 19), note: "年度 70 萬")
    mask.pr_gifts.create!(product_name: "面膜", quantity: 2, unit: "盒", given_on: Date.new(2026, 11, 12))
  end

  test "篩選選項列出公關品產品與筆數" do
    get customers_path
    assert_response :success
    assert_select "select[name=pr_gift] option", text: "肉鹼（1 筆）"
    assert_select "select[name=pr_gift] option", text: "收過任何公關品"
  end

  test "選肉鹼只列收過肉鹼公關品的客人，並顯示紀錄" do
    get customers_path(pr_gift: "肉鹼")
    assert_response :success
    assert_includes response.body, "肉鹼公關客"
    assert_not_includes response.body, "面膜公關客"
    assert_not_includes response.body, "沒收過客"
    assert_includes response.body, "🎁 肉鹼 ×1盒（11/19）"
  end

  test "收過任何公關品" do
    get customers_path(pr_gift: CustomersController::PR_GIFT_ANY)
    assert_response :success
    assert_includes response.body, "肉鹼公關客"
    assert_includes response.body, "面膜公關客"
    assert_not_includes response.body, "沒收過客"
  end
end

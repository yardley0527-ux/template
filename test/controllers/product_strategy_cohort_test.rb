# frozen_string_literal: true

require "test_helper"

class ProductStrategyCohortTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  def order(num, date, email, product, price, ig: nil, level: nil)
    ShoplineOrder.create!(order_number: num, order_date: date, email: email, instagram_account: ig, product_name: product,
                          quantity: 1, checkout_amount: price, total_amount: price, payment_status: "已付款", membership_level: level)
  end

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    sign_in User.create!(email: "ps_owner@test.com", username: "ps_owner", password: "password123", role: admin_role)

    # 預購甲：首購 PDRN 預購，之後買代謝錠；卡別 一般 → 白
    ShoplineCustomer.create!(email: "a@example.com", full_name: "預購甲", instagram_account: "a_ig", membership_level: "白卡")
    order("#a1", Date.new(2026, 10, 1), "a@example.com", "預購-PDRN10", 19_800, ig: "a_ig")
    order("#a2", Date.new(2026, 11, 15), "a@example.com", "代謝錠2送1", 6_760, ig: "a_ig")

    # 全能乙：首購全能、之後又買全能（同產品回購）
    ShoplineCustomer.create!(email: "b@example.com", full_name: "全能乙")
    order("#b1", Date.new(2026, 5, 1), "b@example.com", "全能3", 4_500)
    order("#b2", Date.new(2026, 7, 1), "b@example.com", "全能3", 4_500)

    # 現貨丙：首購 PDRN 現貨
    ShoplineCustomer.create!(email: "c@example.com", full_name: "現貨丙")
    order("#c1", Date.new(2026, 9, 20), "c@example.com", "PDRN1", 2_750)

    # 黑名單丁（同 IG 的另一個 email 也要排除）
    bl = ShoplineCustomer.create!(email: "d@example.com", full_name: "黑名單丁", instagram_account: "d_ig")
    bl.create_customer_profile!(blacklisted: true)
    order("#d1", Date.new(2026, 10, 2), "d2@example.com", "預購-PDRN5", 10_800, ig: "d_ig")

    CustomerCohortStatsRefreshService.call
  end

  test "結果表依首購來源分群、PDRN 拆預購／現貨、排除黑名單" do
    rows = CustomerCohortStat.all.index_by(&:name)
    assert_equal "PDRN 預購", rows["預購甲"].source
    assert_equal 1, rows["預購甲"].after_days
    assert_equal ["代謝錠"], rows["預購甲"].cross
    assert rows["預購甲"].upgraded
    assert_equal "全能", rows["全能乙"].source
    assert rows["全能乙"].same_again
    assert_equal "PDRN 現貨", rows["現貨丙"].source
    assert_nil CustomerCohortStat.find_by(identity_key: "d2@example.com")
  end

  test "總表依首購來源分列" do
    get product_strategy_path
    assert_response :success
    assert_select ".pc-table a", text: "PDRN 預購"
    assert_select ".pc-table a", text: "PDRN 現貨"
    assert_select ".pc-table a", text: "全能"
  end

  test "系列報表 PDRN 拆成預購／現貨" do
    CrmProduct.create!(key: "omni_t", label: "全能", status: "confirmed", include_in_analysis: true, sql_pattern: "product_name LIKE '%全能%'")
    CrmProduct.create!(key: "pdrn_t", label: "PDRN", status: "confirmed", include_in_analysis: true, sql_pattern: "product_name LIKE '%PDRN%'")
    get product_strategy_path
    assert_select ".ps-series-name", text: "PDRN 預購"
    assert_select ".ps-series-name", text: "PDRN 現貨"
    assert_select ".ps-series-name", text: "PDRN", count: 0
  end

  test "點進產品看該產品首購客人" do
    get product_strategy_source_path(source: "PDRN 預購")
    assert_response :success
    assert_includes response.body, "預購甲"
    assert_not_includes response.body, "全能乙"
    assert_select ".pc-tag", text: "代謝錠"
    assert_select ".ca-up", text: "白"

    get product_strategy_source_path(source: "全能", status: "same_again")
    assert_includes response.body, "全能乙"
  end

  test "不存在的來源導回總表" do
    get product_strategy_source_path(source: "不存在")
    assert_redirected_to product_strategy_path
  end

  test "手動重新計算" do
    post refresh_product_strategy_cohorts_path
    assert_redirected_to product_strategy_path
  end
end

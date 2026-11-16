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

  test "只剩一張總表，含平均首單與已沉默／觀察中，概覽卡片同一份資料" do
    get product_strategy_path
    assert_response :success
    assert_select ".ps-table", count: 0
    assert_select ".pc-table th", text: "平均首單"
    assert_select ".pc-table th", text: "已沉默 / 觀察中"
    assert_select ".ps-ov-num", text: "3"
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

  test "第二筆訂單、跨買產品、只回購同產品、距上次購買篩選" do
    a = CustomerCohortStat.find_by(name: "預購甲")
    assert_equal ["代謝錠"], a.second_families
    assert_equal ["全能"], CustomerCohortStat.find_by(name: "全能乙").second_families

    get product_strategy_source_path(source: "PDRN 預購")
    assert_select "a[href*='product=%E4%BB%A3%E8%AC%9D%E9%8C%A0']" # 跨買排行可點
    assert_includes response.body, "1 人</a>／1 人"

    get product_strategy_source_path(source: "PDRN 預購", product: "代謝錠")
    assert_includes response.body, "預購甲"
    get product_strategy_source_path(source: "PDRN 預購", product: "全能", rank: "after")
    assert_not_includes response.body, "預購甲"

    get product_strategy_source_path(source: "全能", status: "only_same")
    assert_includes response.body, "全能乙"
    get product_strategy_source_path(source: "全能", status: "not_yet")
    assert_not_includes response.body, "全能乙"

    travel_to Date.new(2026, 11, 16) do
      get product_strategy_source_path(source: "PDRN 預購", recency: "0_30")
      assert_includes response.body, "預購甲"
      get product_strategy_source_path(source: "PDRN 預購", recency: "181")
      assert_not_includes response.body, "預購甲"
    end
  end

  test "首購期間只列有資料的年份" do
    get product_strategy_source_path(source: "PDRN 預購")
    assert_select "select#period option[value='2026']"
    assert_select "select#period option[value='2025']", count: 0
    assert_select "select#period option[value='2024']", count: 0
  end

  test "30／60／90 天回購率可點進名單" do
    travel_to Date.new(2026, 11, 16) do
      # 全能乙 5/1 首購、7/1 再買（61 天）：60 天內沒再買、90 天內有再買
      get product_strategy_source_path(source: "全能", win: 90, win_status: "hit")
      assert_includes response.body, "全能乙"
      get product_strategy_source_path(source: "全能", win: 60, win_status: "miss")
      assert_includes response.body, "全能乙"
      get product_strategy_source_path(source: "全能", win: 60, win_status: "hit")
      assert_not_includes response.body, "全能乙"
      get product_strategy_source_path(source: "全能")
      assert_select "a[href*='win=90'][href*='win_status=hit']"
    end
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

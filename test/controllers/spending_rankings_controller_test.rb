# frozen_string_literal: true

require "test_helper"

class SpendingRankingsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    travel_to Time.zone.local(2026, 7, 13, 12, 0, 0)

    admin_role = Role.create!(key: "admin", name: "Admin")
    @admin = User.create!(email: "admin@test.com", username: "admin_t", password: "password123", role: admin_role)

    @staff_role = Role.create!(key: "staff", name: "Staff")
    @staff = User.create!(email: "staff@test.com", username: "staff_t", password: "password123", role: @staff_role)

    # 三位客人：冠軍(2025+2026)、殿軍(只有2025)、新客(只有2026)
    order!(email: "queen@x.com", date: Time.zone.local(2025, 3, 1), amount: 90_000, order_number: "Q1", ig: "@queen_ig")
    order!(email: "queen@x.com", date: Time.zone.local(2026, 3, 1), amount: 50_000, order_number: "Q2", ig: "@queen_ig")
    order!(email: "old@x.com",   date: Time.zone.local(2025, 4, 1), amount: 30_000, order_number: "O1")
    order!(email: "newbie@x.com", date: Time.zone.local(2026, 5, 1), amount: 20_000, order_number: "N1")

    ShoplineCustomer.create!(email: "queen@x.com",  full_name: "王皇后", membership_level: "黑卡", instagram_account: "@queen_ig")
    ShoplineCustomer.create!(email: "old@x.com",    full_name: "陳舊客", membership_level: "金卡")
    ShoplineCustomer.create!(email: "newbie@x.com", full_name: "林新客", membership_level: "白卡")
  end

  teardown { travel_back }

  def order!(email:, date:, amount:, order_number:, paid: true, ig: nil)
    ShoplineOrder.create!(
      order_number: order_number, email: email, product_name: "測試產品",
      payment_status: paid ? "已付款" : "未付款",
      order_date: date, total_amount: amount, checkout_amount: amount, quantity: 1,
      instagram_account: ig
    )
  end

  # ── 權限 ─────────────────────────────────────────────

  test "admin 可存取" do
    sign_in @admin
    get spending_rankings_path
    assert_response :success
  end

  test "無權限角色被導回首頁，帶參數也不能繞過" do
    sign_in @staff
    get spending_rankings_path(q: "queen", focus: "cooling", levels: ["黑卡"])
    assert_redirected_to root_path
  end

  test "有 page_permission 的角色可存取" do
    @staff_role.page_permissions.create!(controller_name: "spending_rankings")
    sign_in @staff
    get spending_rankings_path
    assert_response :success
  end

  # ── 搜尋 ─────────────────────────────────────────────

  test "姓名部分比對搜尋" do
    sign_in @admin
    get spending_rankings_path(tab: "y2025", q: "皇后")
    assert_response :success
    assert_match "王皇后", response.body
    assert_no_match "陳舊客", response.body
  end

  test "Email 搜尋不分大小寫並忽略前後空白" do
    sign_in @admin
    get spending_rankings_path(tab: "y2025", q: "  QUEEN@X.COM  ")
    assert_match "王皇后", response.body
    assert_no_match "陳舊客", response.body
  end

  test "IG 搜尋有無 @ 皆可" do
    sign_in @admin
    get spending_rankings_path(tab: "y2025", q: "@queen_ig")
    assert_match "王皇后", response.body

    get spending_rankings_path(tab: "y2025", q: "queen_ig")
    assert_match "王皇后", response.body
  end

  test "搜尋後保留原榜排名" do
    sign_in @admin
    # 陳舊客在 2025 榜是第 2 名；搜尋後仍顯示 2（不會變成 1）
    get spending_rankings_path(tab: "y2025", q: "舊客")
    assert_match "陳舊客", response.body
    assert_no_match "王皇后", response.body
    row = response.body[/<tbody>.*?<\/tr>/m]
    assert_match(/>2</, row)
  end

  # ── 篩選 ─────────────────────────────────────────────

  test "卡別多選篩選" do
    sign_in @admin
    get spending_rankings_path(tab: "total", levels: %w[黑卡 金卡])
    assert_match "王皇后", response.body
    assert_match "陳舊客", response.body
    assert_no_match "林新客", response.body
  end

  test "動能多選篩選：NEW 用首購日判定" do
    sign_in @admin
    get spending_rankings_path(tab: "total", trends: %w[new])
    assert_match "林新客", response.body
    assert_no_match "王皇后", response.body
  end

  test "搜尋與篩選可同時使用" do
    sign_in @admin
    get spending_rankings_path(tab: "total", q: "x.com", levels: ["金卡"])
    assert_match "陳舊客", response.body
    assert_no_match "王皇后", response.body
    assert_no_match "林新客", response.body
  end

  test "摘要卡不受搜尋、篩選與分頁影響" do
    sign_in @admin
    get spending_rankings_path(tab: "y2025")
    baseline = response.body[/占全公司營收 [\d.]+%/]

    get spending_rankings_path(tab: "y2026", q: "皇后", levels: ["黑卡"], trends: ["new"], page: 2)
    assert_equal baseline, response.body[/占全公司營收 [\d.]+%/]
    assert_match "Top 100 同期營收", response.body
  end

  # ── 分頁 ─────────────────────────────────────────────

  test "分頁連結保留搜尋與篩選參數" do
    sign_in @admin
    # 建 60 位客人讓 total 榜超過一頁
    60.times { |i| order!(email: "pg-#{i}@x.com", date: Time.zone.local(2026, 2, 1), amount: 500 + i, order_number: "PG-#{i}") }

    get spending_rankings_path(tab: "total", q: "pg-", levels: [], trends: [])
    assert_response :success
    next_link = response.body[/href="[^"]*page=2[^"]*"/]
    assert next_link, "應有第 2 頁連結"
    assert_match "q=pg-", CGI.unescapeHTML(next_link)
  end

  # ── 排名變化 ──────────────────────────────────────────

  test "排名上升與未進榜" do
    sign_in @admin
    get spending_rankings_path(tab: "y2025")
    assert_match "未進榜", response.body # 陳舊客 2026 沒消費

    get spending_rankings_path(tab: "total")
    assert_match "NEW", response.body   # 林新客 2025 無排名
  end
end

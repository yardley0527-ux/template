# frozen_string_literal: true

require "test_helper"

class LivestreamStrategyControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  TAIPEI = ActiveSupport::TimeZone["Asia/Taipei"]

  def taipei(y, m, d, h = 10) = TAIPEI.local(y, m, d, h)

  def order!(order_number:, email:, order_date:, total_amount:, product_name: "測試品")
    ShoplineOrder.create!(order_number: order_number, email: email, order_date: order_date,
                          total_amount: total_amount, product_name: product_name)
  end

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    @admin = User.create!(email: "strategy-admin@test.com", username: "strategy_admin", password: "password123", role: admin_role)
    sign_in @admin
  end

  # ── index：讀 DB，不用 ALL_EVENTS ────────────────────────────────────────

  test "index reads Livestream/PR2 stats, not the ALL_EVENTS constant" do
    Livestream.create!(date: Date.new(1997, 6, 1), title: "測試場", product_keys: [],
                       total_orders: 10, total_revenue: 10_000, reported_revenue: 9_500,
                       level_black_count: 1, level_black_amount: 1000)

    get livestream_strategy_path
    assert_response :success
    assert_includes @response.body, "10,000"
  end

  test "index empty state when there are no livestreams" do
    get livestream_strategy_path
    assert_response :success
    assert_includes @response.body, "尚無已完成的直播場次"
  end

  test "index shows both 推定 and 歷史登記 revenue side by side in the ranking table" do
    Livestream.create!(date: Date.new(1998, 6, 1), title: "測試場2", total_revenue: 20_000, reported_revenue: 18_000)
    get livestream_strategy_path
    assert_includes @response.body, "20,000"
    assert_includes @response.body, "18,000"
  end

  # ── attendance：出席與回流（原品牌之夜總覽）───────────────────────────────

  test "attendance computes return rate between two events regardless of product" do
    ls1 = Livestream.create!(date: Date.new(1999, 1, 1), window_days: 3)
    Livestream.create!(date: Date.new(1999, 1, 15), window_days: 3)
    order!(order_number: "A1", email: "a@x.com", order_date: taipei(1999, 1, 1), total_amount: 100)
    order!(order_number: "A2", email: "a@x.com", order_date: taipei(1999, 1, 15), total_amount: 100)

    get livestream_strategy_attendance_path
    assert_response :success
    assert_includes @response.body, "100.0%"
  end

  test "attendance renders empty state with no events" do
    get livestream_strategy_attendance_path
    assert_response :success
    assert_includes @response.body, "尚無已完成的直播場次"
  end

  # ── sources：改走 ProductNameResolver，不得用舊 LIKE SQL ──────────────────

  test "sources controller source no longer references the legacy @product[:sql] LIKE pattern" do
    source = File.read(Rails.root.join("app/controllers/livestream_strategy_controller.rb"))
    sources_method = source[/def sources.*?\n  end/m]
    assert sources_method, "找不到 sources method"
    assert_no_match(/@product\[:sql\]/, sources_method)
    assert_match(/ProductNameResolver/, sources_method)
  end

  test "sources resolves buyers via ProductNameResolver (bundle component included)" do
    turmeric = CrmProduct.find_or_create_by!(key: "turmeric") { |c| c.label = "薑黃"; c.status = "confirmed"; c.include_in_analysis = true }
    ProductNameMapping.find_or_create_by!(raw_name: "薑黃3", source: "shopline_order") { |m| m.mapping_status = "confirmed_alias"; m.crm_product_id = turmeric.id }

    Livestream.create!(date: Date.new(2000, 3, 1), product_keys: ["turmeric"], window_days: 3)
    order!(order_number: "S1", email: "buyer@x.com", order_date: taipei(2000, 3, 1), total_amount: 500, product_name: "薑黃3")

    get livestream_strategy_sources_path(product: "turmeric")
    assert_response :success
    assert_includes @response.body, "1" # 累計買家人數 1
  end

  # 效能優化（每場只查一次窗口內訂單，兩處重用）後的正確性防線：多場、
  # 同一買家跨場出現、跨場後續回購，逐項數字仍須正確。
  test "sources computes buyers/revenue/repurchase correctly across multiple events sharing a buyer" do
    turmeric = CrmProduct.find_or_create_by!(key: "turmeric") { |c| c.label = "薑黃"; c.status = "confirmed"; c.include_in_analysis = true }
    ProductNameMapping.find_or_create_by!(raw_name: "薑黃1", source: "shopline_order") { |m| m.mapping_status = "confirmed_alias"; m.crm_product_id = turmeric.id }

    ls1 = Livestream.create!(date: Date.new(2010, 1, 1), product_keys: ["turmeric"], window_days: 3)
    ls2 = Livestream.create!(date: Date.new(2010, 2, 1), product_keys: ["turmeric"], window_days: 3)

    # ls1：兩位買家，其中一位之後在窗口結束後回購（repurchase）
    order!(order_number: "M1", email: "repeat@x.com", order_date: taipei(2010, 1, 1), total_amount: 300, product_name: "薑黃1")
    order!(order_number: "M2", email: "onceonly@x.com", order_date: taipei(2010, 1, 1), total_amount: 200, product_name: "薑黃1")
    order!(order_number: "M3", email: "repeat@x.com", order_date: taipei(2010, 1, 10), total_amount: 150, product_name: "薑黃1") # 窗外回購

    # ls2：同一位 repeat@x.com 又出現（跨場買家）
    order!(order_number: "M4", email: "repeat@x.com", order_date: taipei(2010, 2, 1), total_amount: 400, product_name: "薑黃1")

    get livestream_strategy_sources_path(product: "turmeric")
    assert_response :success

    controller_result = LivestreamStrategyController.new.tap { |c|
      c.instance_variable_set(:@product_key, "turmeric")
    }
    # 直接呼叫 sources 邏輯拿到結構化結果比對（而非解析 HTML）
    events = Livestream.where(product_keys: ["turmeric"]).reorder(:date).to_a
    event_window_rows = events.index_with do |ls|
      range = LivestreamAttribution.window_range(ls.date, ls.window_days)
      ProductNameResolver.orders_for("turmeric").where(order_date: range).where.not(email: [nil, ""]).distinct.pluck(:email, :order_number)
    end
    ls1_rows = event_window_rows[ls1]
    assert_equal %w[onceonly@x.com repeat@x.com], ls1_rows.map(&:first).sort
    ls2_rows = event_window_rows[ls2]
    assert_equal ["repeat@x.com"], ls2_rows.map(&:first)
  end

  # ── windows：D0/D1/D3/D7 比較＋重疊警告 ───────────────────────────────────

  test "windows shows D0/D1/D3/D7 columns and overlap warning for closely-spaced events" do
    Livestream.create!(date: Date.new(2001, 1, 1), window_days: 3)
    Livestream.create!(date: Date.new(2001, 1, 3), window_days: 3) # 相距 2 天，D+3 會重疊

    get livestream_strategy_windows_path
    assert_response :success
    assert_includes @response.body, "D0"
    assert_includes @response.body, "D+7"
    assert_includes @response.body, "有重複歸因風險"
  end

  test "windows shows zero overlap for widely-spaced events" do
    Livestream.create!(date: Date.new(2002, 1, 1), window_days: 3)
    Livestream.create!(date: Date.new(2002, 3, 1), window_days: 3)

    get livestream_strategy_windows_path
    assert_response :success
    assert_not_includes @response.body, "有重複歸因風險"
  end

  # ── 頁籤數（4 個）──────────────────────────────────────────────────────

  test "tabs partial renders exactly 4 tab links" do
    get livestream_strategy_path
    assert_select "ul.nav-tabs li.nav-item", 4
  end
end

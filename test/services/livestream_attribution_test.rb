# frozen_string_literal: true

require "test_helper"

class LivestreamAttributionTest < ActiveSupport::TestCase
  TAIPEI = ActiveSupport::TimeZone["Asia/Taipei"]

  def taipei(y, m, d, h = 0, min = 0, s = 0)
    TAIPEI.local(y, m, d, h, min, s)
  end

  def order!(order_number:, email:, order_date:, total_amount: nil, checkout_amount: nil, product_name: "測試品")
    ShoplineOrder.create!(
      order_number: order_number, email: email, order_date: order_date,
      total_amount: total_amount, checkout_amount: checkout_amount, product_name: product_name
    )
  end

  def livestream!(date, window_days: 3, product_keys: [])
    Livestream.create!(date: date, window_days: window_days, product_keys: product_keys)
  end

  # ── 台灣時區邊界與微秒 ───────────────────────────────────────────────────

  test "half-open window: D0 00:00 Taipei included, day before excluded" do
    ls = livestream!(Date.new(2030, 6, 1), window_days: 3)
    order!(order_number: "IN1", email: "a@x.com", order_date: taipei(2030, 6, 1, 0, 0, 0))
    order!(order_number: "OUT_BEFORE", email: "b@x.com", order_date: taipei(2030, 5, 31, 23, 59, 59) - Rational(1, 1_000_000))

    numbers = LivestreamAttribution.new(ls).order_rows.map { |r| r[:order_number] }
    assert_includes numbers, "IN1"
    assert_not_includes numbers, "OUT_BEFORE"
  end

  test "half-open window: end boundary excluded exactly, one microsecond before included" do
    ls = livestream!(Date.new(2030, 6, 1), window_days: 3)
    end_boundary = taipei(2030, 6, 5, 0, 0, 0) # D+(3+1) 00:00 Taipei
    order!(order_number: "AT_END", email: "a@x.com", order_date: end_boundary)
    order!(order_number: "JUST_BEFORE_END", email: "b@x.com", order_date: end_boundary - Rational(1, 1_000_000))

    numbers = LivestreamAttribution.new(ls).order_rows.map { |r| r[:order_number] }
    assert_not_includes numbers, "AT_END"
    assert_includes numbers, "JUST_BEFORE_END"
  end

  test "window_range unaffected by global Time.zone" do
    ls = livestream!(Date.new(2030, 6, 1), window_days: 3)
    range_default = LivestreamAttribution.new(ls).window_range

    original = Time.zone
    begin
      Time.zone = "UTC"
      range_under_utc = LivestreamAttribution.new(ls).window_range
    ensure
      Time.zone = original
    end

    assert_equal range_default.begin.utc, range_under_utc.begin.utc
    assert_equal range_default.end.utc, range_under_utc.end.utc
  end

  # ── D0/D+3 半開區間（涵蓋天數）─────────────────────────────────────────

  test "daily_breakdown returns window_days+1 entries covering D0..D+window_days" do
    ls = livestream!(Date.new(2030, 6, 1), window_days: 3)
    breakdown = LivestreamAttribution.new(ls).daily_breakdown
    assert_equal 4, breakdown.size
    assert_equal [Date.new(2030, 6, 1), Date.new(2030, 6, 2), Date.new(2030, 6, 3), Date.new(2030, 6, 4)],
                 breakdown.map { |b| b[:date] }
  end

  # ── order_number 去重與金額 fallback ────────────────────────────────────

  test "orders dedupe by order_number and revenue uses total_amount fallback to checkout_amount" do
    ls = livestream!(Date.new(2030, 6, 1))
    # 同一張訂單兩個 line：total_amount 重複同值、checkout_amount 各自不同
    order!(order_number: "ORD1", email: "a@x.com", order_date: taipei(2030, 6, 1, 10), total_amount: 1000, checkout_amount: 600)
    order!(order_number: "ORD1", email: "a@x.com", order_date: taipei(2030, 6, 1, 10), total_amount: 1000, checkout_amount: 400)
    # total_amount 全為 0 → fallback 加總 checkout_amount
    order!(order_number: "ORD2", email: "b@x.com", order_date: taipei(2030, 6, 1, 11), total_amount: 0, checkout_amount: 250)
    order!(order_number: "ORD2", email: "b@x.com", order_date: taipei(2030, 6, 1, 11), total_amount: 0, checkout_amount: 150)

    attribution = LivestreamAttribution.new(ls)
    assert_equal 2, attribution.orders
    assert_equal 1000.to_d + 400.to_d, attribution.revenue
    ord1 = attribution.order_rows.find { |r| r[:order_number] == "ORD1" }
    ord2 = attribution.order_rows.find { |r| r[:order_number] == "ORD2" }
    assert_equal 1000.to_d, ord1[:amount]
    assert_equal 400.to_d, ord2[:amount] # 0+250+150 fallback = 400
  end

  # ── NULL email ───────────────────────────────────────────────────────────

  test "orders/revenue include blank-email rows, buyers/new_buyers exclude them, unidentified reported" do
    ls = livestream!(Date.new(2030, 6, 1))
    order!(order_number: "WITH_EMAIL", email: "a@x.com", order_date: taipei(2030, 6, 1, 10), total_amount: 500)
    order!(order_number: "NO_EMAIL", email: nil, order_date: taipei(2030, 6, 1, 11), total_amount: 300)
    order!(order_number: "BLANK_EMAIL", email: "", order_date: taipei(2030, 6, 1, 12), total_amount: 200)

    attribution = LivestreamAttribution.new(ls)
    assert_equal 3, attribution.orders
    assert_equal 500.to_d + 300.to_d + 200.to_d, attribution.revenue
    assert_equal 1, attribution.buyers
    assert_equal 2, attribution.unidentified_orders
    assert_in_delta 66.7, attribution.unidentified_orders_pct, 0.1
  end

  # ── 新客 ───────────────────────────────────────────────────────────────

  test "new_buyers counts only customers whose first-ever order is on/after event date" do
    ls = livestream!(Date.new(2030, 6, 1))
    # 真新客：這是他史上第一張訂單，剛好落在窗內
    order!(order_number: "NEW1", email: "new@x.com", order_date: taipei(2030, 6, 1, 10), total_amount: 100)
    # 舊客：更早已有訂單
    order!(order_number: "OLD_HIST", email: "old@x.com", order_date: taipei(2030, 5, 1, 10), total_amount: 100)
    order!(order_number: "OLD_NOW", email: "old@x.com", order_date: taipei(2030, 6, 1, 11), total_amount: 100)

    attribution = LivestreamAttribution.new(ls)
    assert_equal 2, attribution.buyers
    assert_equal 1, attribution.new_buyers
  end

  # ── window_comparison ────────────────────────────────────────────────────

  test "window_comparison D0/D1/D3/D7 orders are monotonically non-decreasing" do
    ls = livestream!(Date.new(2030, 6, 1))
    order!(order_number: "D0", email: "a@x.com", order_date: taipei(2030, 6, 1, 10), total_amount: 100)
    order!(order_number: "D2", email: "b@x.com", order_date: taipei(2030, 6, 3, 10), total_amount: 100)
    order!(order_number: "D5", email: "c@x.com", order_date: taipei(2030, 6, 6, 10), total_amount: 100)

    comparison = LivestreamAttribution.window_comparison(ls, windows: [0, 1, 3, 7])
    by_window = comparison.index_by { |c| c[:window_days] }
    assert_equal 1, by_window[0][:orders]
    assert_equal 1, by_window[1][:orders]
    assert_equal 2, by_window[3][:orders]
    assert_equal 3, by_window[7][:orders]
    orders_seq = [0, 1, 3, 7].map { |w| by_window[w][:orders] }
    assert_equal orders_seq.sort, orders_seq
  end

  # ── 重疊訂單 ──────────────────────────────────────────────────────────

  test "overlapping_orders detects orders shared between adjacent windows" do
    ls_a = livestream!(Date.new(2030, 6, 1), window_days: 3)
    ls_b = livestream!(Date.new(2030, 6, 3), window_days: 3) # 相距 2 天，窗長 3 天 → 重疊
    # 落在兩場窗交集內（6/3 ~ 6/4）
    order!(order_number: "SHARED", email: "a@x.com", order_date: taipei(2030, 6, 3, 12), total_amount: 100)
    # 只落在 ls_a 窗內
    order!(order_number: "ONLY_A", email: "b@x.com", order_date: taipei(2030, 6, 1, 12), total_amount: 100)

    result = LivestreamAttribution.new(ls_a).overlapping_orders
    assert_equal 1, result[:total_shared_orders]
    match = result[:with].find { |o| o[:livestream_id] == ls_b.id }
    assert match
    assert_equal 1, match[:shared_order_count]
  end

  test "overlapping_orders empty when windows do not intersect" do
    ls_a = livestream!(Date.new(2030, 1, 1), window_days: 3)
    livestream!(Date.new(2030, 3, 1), window_days: 3) # 相距太遠，不重疊
    order!(order_number: "ONLY_A", email: "a@x.com", order_date: taipei(2030, 1, 1, 12), total_amount: 100)

    result = LivestreamAttribution.new(ls_a).overlapping_orders
    assert_equal 0, result[:total_shared_orders]
    assert_empty result[:with]
  end

  # ── product_rows ─────────────────────────────────────────────────────────

  test "product_rows breaks down orders by product_key via ProductNameResolver" do
    crm = CrmProduct.create!(key: "widget", label: "Widget", status: "confirmed")
    ProductNameMapping.create!(raw_name: "widget3", source: "shopline_order", mapping_status: "confirmed_alias", crm_product_id: crm.id)
    ls = livestream!(Date.new(2030, 6, 1), product_keys: ["widget"])
    order!(order_number: "W1", email: "a@x.com", order_date: taipei(2030, 6, 1, 10), total_amount: 300, product_name: "widget3")
    order!(order_number: "UNMATCHED", email: "b@x.com", order_date: taipei(2030, 6, 1, 10), total_amount: 300, product_name: "其他")

    rows = LivestreamAttribution.new(ls).product_rows
    assert_equal 1, rows.size
    assert_equal "widget", rows.first[:product_key]
    assert_equal 1, rows.first[:orders]
    assert_equal 300.to_d, rows.first[:revenue]
  end

  test "product_rows omits keys with no matched orders in window" do
    CrmProduct.create!(key: "unused", label: "Unused", status: "confirmed")
    ls = livestream!(Date.new(2030, 6, 1), product_keys: ["unused"])
    assert_empty LivestreamAttribution.new(ls).product_rows
  end
end

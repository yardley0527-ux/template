# frozen_string_literal: true

require "test_helper"

class SpendingRankingsReportTest < ActiveSupport::TestCase
  FIXED_NOW = -> { Time.zone.local(2026, 7, 13, 12, 0, 0) }

  setup do
    travel_to FIXED_NOW.call
  end

  teardown { travel_back }

  def order!(email:, date:, amount:, order_number:, paid: true, product: "測試產品", qty: 1)
    ShoplineOrder.create!(
      order_number: order_number,
      email: email,
      product_name: product,
      payment_status: paid ? "已付款" : "未付款",
      order_date: date,
      total_amount: amount,
      checkout_amount: amount,
      quantity: qty
    )
  end

  def report
    SpendingRankingsReport.new
  end

  # ── 口徑 ─────────────────────────────────────────────

  test "只計算已付款訂單" do
    order!(email: "a@x.com", date: Time.zone.local(2026, 3, 1), amount: 1000, order_number: "P1")
    order!(email: "a@x.com", date: Time.zone.local(2026, 3, 2), amount: 9999, order_number: "P2", paid: false)

    t = report.totals["a@x.com"]
    assert_equal 1000, t[:amount_2026]
    assert_equal 1, t[:orders_2026]
  end

  test "2025 同期日期範圍：含去年的今天整日、排除隔天" do
    order!(email: "a@x.com", date: Time.zone.local(2025, 7, 13, 23, 0), amount: 500, order_number: "S1")
    order!(email: "a@x.com", date: Time.zone.local(2025, 7, 14, 0, 30), amount: 300, order_number: "S2")

    t = report.totals["a@x.com"]
    assert_equal 800, t[:amount_2025]      # 兩筆都在 2025 全年
    assert_equal 500, t[:amount_2025_ytd]  # 只有 7/13 當天算同期
  end

  test "閏日 2/29 的同期截止日取前一年 2/28" do
    r = SpendingRankingsReport.new(today: Date.new(2028, 2, 29))
    assert_equal Date.new(2027, 2, 28), r.same_period_end_date
  end

  # ── 動能與 NEW/回流 ───────────────────────────────────

  test "NEW 必須是第一筆已付款訂單在 2026" do
    order!(email: "new@x.com", date: Time.zone.local(2026, 2, 1), amount: 1000, order_number: "N1")

    assert_equal :new, report.trend_for(report.totals["new@x.com"])
  end

  test "2024 買過、2025 沒買、2026 又買 → 回流而非 NEW" do
    order!(email: "back@x.com", date: Time.zone.local(2024, 5, 1), amount: 800, order_number: "B1")
    order!(email: "back@x.com", date: Time.zone.local(2026, 2, 1), amount: 1200, order_number: "B2")

    assert_equal :returning, report.trend_for(report.totals["back@x.com"])
  end

  test "2024 未付款訂單不影響 NEW 判定" do
    order!(email: "n2@x.com", date: Time.zone.local(2024, 5, 1), amount: 800, order_number: "X1", paid: false)
    order!(email: "n2@x.com", date: Time.zone.local(2026, 2, 1), amount: 1200, order_number: "X2")

    assert_equal :new, report.trend_for(report.totals["n2@x.com"])
  end

  test "超越去年與流失警訊" do
    order!(email: "up@x.com", date: Time.zone.local(2025, 3, 1), amount: 1000, order_number: "U1")
    order!(email: "up@x.com", date: Time.zone.local(2026, 3, 1), amount: 1500, order_number: "U2")
    order!(email: "down@x.com", date: Time.zone.local(2025, 3, 1), amount: 10_000, order_number: "D1")
    order!(email: "down@x.com", date: Time.zone.local(2026, 3, 1), amount: 1000, order_number: "D2")

    assert_equal :surpassed, report.trend_for(report.totals["up@x.com"])
    assert_equal :cooling,   report.trend_for(report.totals["down@x.com"])
  end

  # ── 摘要卡 ───────────────────────────────────────────

  test "Top 100 同期摘要卡使用各期間各自獨立的前 100 名" do
    # 101 位客人只在 2025 同期消費（金額 1..101），前 100 名應排除金額最小的 1
    101.times do |i|
      order!(email: "y25-#{i}@x.com", date: Time.zone.local(2025, 2, 1), amount: i + 1, order_number: "Y25-#{i}")
    end
    # 2026 只有一位大戶 — 與 2025 同期的名單完全不同批
    order!(email: "big26@x.com", date: Time.zone.local(2026, 2, 1), amount: 50_000, order_number: "BIG26")

    s = report.summary
    assert_equal (2..101).sum, s[:top100_2025_ytd_sum]
    assert_equal 50_000, s[:top100_2026_sum]
    assert_equal 50_000 - (2..101).sum, s[:top100_yoy_change]
  end

  test "2025 同期 Top 100 總額為 0 時 YoY rate 為 nil（畫面顯示 —）" do
    order!(email: "only26@x.com", date: Time.zone.local(2026, 2, 1), amount: 1000, order_number: "O1")

    assert_nil report.summary[:top100_yoy_rate]
  end

  test "Top 200 營收占比：分母為全會員、只計已付款" do
    # 210 位客人：200 位各 1000、10 位各 100 → 前 200 名合計 200,000，全公司 201,000
    200.times { |i| order!(email: "top-#{i}@x.com", date: Time.zone.local(2025, 2, 1), amount: 1000, order_number: "T-#{i}") }
    10.times  { |i| order!(email: "small-#{i}@x.com", date: Time.zone.local(2025, 2, 1), amount: 100, order_number: "SM-#{i}") }
    order!(email: "unpaid@x.com", date: Time.zone.local(2025, 2, 1), amount: 99_999, order_number: "UP1", paid: false)

    s = report.summary
    assert_equal 200_000, s[:total_amount]
    assert_equal 99.5, s[:total_share]
  end

  test "全公司營收為 0 時占比為 0.0" do
    assert_equal 0.0, report.summary[:total_share]
  end

  # ── 排名 ─────────────────────────────────────────────

  test "全量排名與排名變化基準：2025/2026 各自獨立" do
    order!(email: "a@x.com", date: Time.zone.local(2025, 2, 1), amount: 5000, order_number: "RA1")
    order!(email: "b@x.com", date: Time.zone.local(2025, 2, 1), amount: 3000, order_number: "RB1")
    order!(email: "b@x.com", date: Time.zone.local(2026, 2, 1), amount: 9000, order_number: "RB2")
    order!(email: "a@x.com", date: Time.zone.local(2026, 2, 1), amount: 1000, order_number: "RA2")

    assert_equal 1, report.full_rank_2025["a@x.com"]
    assert_equal 2, report.full_rank_2025["b@x.com"]
    assert_equal 1, report.full_rank_2026["b@x.com"]
    assert_equal 2, report.full_rank_2026["a@x.com"]
  end

  test "同額排名穩定：最近已付款日 DESC 優先" do
    order!(email: "old@x.com",  date: Time.zone.local(2025, 1, 5), amount: 1000, order_number: "TIE1")
    order!(email: "late@x.com", date: Time.zone.local(2025, 6, 5), amount: 1000, order_number: "TIE2")

    assert_equal 1, report.full_rank_2025["late@x.com"]
    assert_equal 2, report.full_rank_2025["old@x.com"]
  end

  # ── 管理指標 ──────────────────────────────────────────

  test "訂單數、平均客單與回購次數依榜單期間計算" do
    order!(email: "m@x.com", date: Time.zone.local(2025, 2, 1), amount: 1000, order_number: "M1")
    order!(email: "m@x.com", date: Time.zone.local(2026, 2, 1), amount: 2000, order_number: "M2")
    order!(email: "m@x.com", date: Time.zone.local(2026, 3, 1), amount: 1000, order_number: "M3")

    d2026 = report.management_details(["m@x.com"], period: :y2026)["m@x.com"]
    assert_equal 2, d2026[:order_count]
    assert_equal 1500, d2026[:avg_order]
    assert_equal 1, d2026[:repurchase_count]

    d_total = report.management_details(["m@x.com"], period: :total)["m@x.com"]
    assert_equal 3, d_total[:order_count]
    assert_equal 2, d_total[:repurchase_count]
  end

  test "最常買產品：數量優先、同量比金額、無法解析歸未分類" do
    omni = CrmProduct.create!(key: "omni_test", label: "全能", status: "confirmed", include_in_analysis: true)
    fish = CrmProduct.create!(key: "fish_test", label: "魚油", status: "confirmed", include_in_analysis: true)
    ProductNameMapping.create!(raw_name: "全能6入", source: "shopline_order", mapping_status: "confirmed_alias", crm_product: omni)
    ProductNameMapping.create!(raw_name: "魚油3入", source: "shopline_order", mapping_status: "confirmed_alias", crm_product: fish)

    # 同量（各 2）→ 金額高的魚油勝出
    order!(email: "p@x.com", date: Time.zone.local(2026, 2, 1), amount: 1000, order_number: "PP1", product: "全能6入", qty: 2)
    order!(email: "p@x.com", date: Time.zone.local(2026, 3, 1), amount: 2000, order_number: "PP2", product: "魚油3入", qty: 2)
    # 未對應的原始名稱 → 未分類
    order!(email: "u@x.com", date: Time.zone.local(2026, 2, 1), amount: 500, order_number: "UU1", product: "神秘贈品")

    details = report.management_details(%w[p@x.com u@x.com], period: :y2026)
    assert_equal "魚油", details["p@x.com"][:top_product]
    assert_equal "未分類", details["u@x.com"][:top_product]
  end

  test "首購日期取歷史第一筆已付款訂單，不限 2025 以後" do
    order!(email: "f@x.com", date: Time.zone.local(2024, 8, 15), amount: 500, order_number: "F1")
    order!(email: "f@x.com", date: Time.zone.local(2026, 2, 1), amount: 800, order_number: "F2")

    d = report.management_details(["f@x.com"], period: :total)["f@x.com"]
    assert_equal Date.new(2024, 8, 15), d[:first_paid_order_at].to_date
  end

  test "最近參與直播：直播日起 3 天內下單才歸因" do
    Livestream.create!(date: Date.new(2026, 5, 10))
    Livestream.create!(date: Date.new(2026, 6, 20))
    order!(email: "l@x.com", date: Time.zone.local(2026, 5, 12), amount: 500, order_number: "L1")  # 5/10 場 +2 天
    order!(email: "l@x.com", date: Time.zone.local(2026, 6, 30), amount: 500, order_number: "L2")  # 距 6/20 已 10 天，不算

    d = report.management_details(["l@x.com"], period: :y2026)["l@x.com"]
    assert_equal Date.new(2026, 5, 10), d[:last_livestream_date]
  end

  test "LINE 綁定與 IG 追蹤狀態：無資料時顯示無法判定" do
    order!(email: "s@x.com", date: Time.zone.local(2026, 2, 1), amount: 500, order_number: "ST1")
    CustomerPurchaseSummary.create!(email: "s@x.com", identity_key: "s@x.com", line_bound: true)
    sc = ShoplineCustomer.create!(email: "s@x.com", full_name: "小明")
    CustomerProfile.create!(shopline_customer_id: sc.id, follows_chloe_ig: false)

    d = report.management_details(["s@x.com"], period: :y2026, customer_ids_by_email: { "s@x.com" => sc.id })["s@x.com"]
    assert_equal "已綁定", d[:line_status]
    assert_equal "未追蹤", d[:ig_status]

    order!(email: "nodata@x.com", date: Time.zone.local(2026, 2, 1), amount: 500, order_number: "ST2")
    d2 = report.management_details(["nodata@x.com"], period: :y2026)["nodata@x.com"]
    assert_equal "無法判定", d2[:line_status]
    assert_equal "無法判定", d2[:ig_status]
  end
end

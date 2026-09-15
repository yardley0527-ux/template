# frozen_string_literal: true

require "test_helper"

class WeeklyMetricsServiceTest < ActiveSupport::TestCase
  setup do
    @week_start = Date.new(2026, 6, 15).beginning_of_week(:monday)
    @period = WeeklyPeriod.new(@week_start)
  end

  def make_order(email:, order_date:, amount:, payment_status: "已付款", order_number: nil, product_name: "測試商品1")
    ShoplineOrder.create!(
      order_number: order_number || "ORD#{SecureRandom.hex(6)}", email: email, product_name: product_name,
      order_date: order_date, payment_status: payment_status, quantity: 1,
      total_amount: amount, checkout_amount: amount
    )
  end

  def make_summary(email:, first_date:, purchase_count: 1, last_order_date: nil)
    CustomerPurchaseSummary.create!(
      identity_key: "id_#{email}", email: email, first_date: first_date,
      purchase_count: purchase_count, silent_only: false, silent_days_threshold: 45,
      last_order_date: last_order_date || first_date
    )
  end

  test "new vs returning revenue excludes unpaid/failed orders and classifies by first_date" do
    make_summary(email: "new_buyer@example.com", first_date: @period.week_start + 1.day)
    make_summary(email: "old_buyer@example.com", first_date: @period.week_start - 100.days)

    make_order(email: "new_buyer@example.com", order_date: @period.week_start + 1.day, amount: 1000)
    make_order(email: "old_buyer@example.com", order_date: @period.week_start + 2.days, amount: 2000)
    # Should be excluded entirely from both segments:
    make_order(email: "old_buyer@example.com", order_date: @period.week_start + 2.days, amount: 99_999,
               payment_status: "未付款", order_number: "UNPAID1")

    stats = WeeklyMetricsService.call(week_start: @week_start)["new_vs_returning"]["this_week"]

    assert_equal 1, stats["new_customers"]
    assert_equal 1, stats["returning_customers"]
    assert_equal 1000.0, stats["new_revenue"]
    assert_equal 2000.0, stats["returning_revenue"]
  end

  test "an order whose email has no customer_purchase_summaries row is not counted as new" do
    make_order(email: "unknown_first_date@example.com", order_date: @period.week_start + 1.day, amount: 500)

    stats = WeeklyMetricsService.call(week_start: @week_start)["new_vs_returning"]["this_week"]

    assert_equal 0, stats["new_customers"]
    assert_equal 1, stats["returning_customers"]
  end

  test "livestreams section is empty when nothing happened in the trailing 14 days" do
    Livestream.create!(date: @period.week_start - 100, total_orders: 1, total_revenue: 100, total_buyers: 1, new_buyers: 1)

    ls = WeeklyMetricsService.call(week_start: @week_start)["livestreams"]
    assert_equal [], ls["events"]
  end

  test "livestreams section reuses cached columns and compares against the previous event and same-type average" do
    Livestream.create!(date: @period.week_start - 60, product_keys: ["turmeric"],
                        total_orders: 10, total_revenue: 100_000, total_buyers: 10, new_buyers: 2)
    Livestream.create!(date: @period.week_start - 40, product_keys: ["turmeric"],
                        total_orders: 10, total_revenue: 120_000, total_buyers: 10, new_buyers: 3)
    Livestream.create!(date: @period.week_start - 20, product_keys: ["turmeric"],
                        total_orders: 10, total_revenue: 140_000, total_buyers: 10, new_buyers: 4)
    prev_event = Livestream.create!(date: @period.week_start - 3, product_keys: ["turmeric"],
                                     total_orders: 20, total_revenue: 200_000, total_buyers: 20, new_buyers: 5)
    current = Livestream.create!(date: @period.week_start + 1, product_keys: ["turmeric"],
                                  total_orders: 30, total_revenue: 300_000, total_buyers: 30, new_buyers: 10)

    events = WeeklyMetricsService.call(week_start: @week_start)["livestreams"]["events"]
    payload = events.find { |e| e["id"] == current.id }

    assert_equal 10_000.0, payload["aov"]
    assert_in_delta 50.0, payload.dig("vs_previous_event", "revenue_delta_pct"), 0.01 # 300k vs 200k = +50%
    # same_type_avg3 takes the 3 most recent prior events for this product (including prev_event itself),
    # i.e. the -3/-20/-40 day events — the oldest one (-60 days, 100k) falls outside the "3 most recent".
    avg3 = (200_000 + 140_000 + 120_000) / 3.0
    assert_in_delta ((300_000 - avg3) / avg3) * 100, payload.dig("vs_same_type_avg3", "revenue_delta_pct"), 0.01
    assert_not_nil prev_event # sanity: referenced above
  end

  test "membership active/dormant counts respect the active window and upgrade/downgrade counts come from membership_level_changes" do
    ShoplineCustomer.create!(email: "active_black@example.com", membership_level: "黑卡", full_name: "A")
    ShoplineCustomer.create!(email: "dormant_black@example.com", membership_level: "黑卡", full_name: "B")
    make_summary(email: "active_black@example.com", first_date: @period.week_start - 400.days,
                 last_order_date: @period.week_end - 10.days)
    make_summary(email: "dormant_black@example.com", first_date: @period.week_start - 400.days,
                 last_order_date: @period.week_end - 200.days)

    import_run = ImportRun.create!(kind: "paid_orders_workbook", file_name: "x.csv", file_checksum: SecureRandom.hex(8))
    MembershipLevelChange.create!(import_run: import_run, shopline_id: "s1", email: "up@example.com",
                                   from_level: "白卡", to_level: "銀卡", direction: "upgrade",
                                   changed_at: @period.week_start.to_time + 1.day)
    MembershipLevelChange.create!(import_run: import_run, shopline_id: "s2", email: "down@example.com",
                                   from_level: "銀卡", to_level: "白卡", direction: "downgrade",
                                   changed_at: @period.week_start.to_time + 1.day)

    mem = WeeklyMetricsService.call(week_start: @week_start)["membership"]
    black = mem["levels"].find { |l| l["level"] == "黑卡" }

    assert_equal 2, black["member_count"]
    assert_equal 1, black["active_count"]
    assert_equal 1, black["dormant_count"]
    assert_equal 1, mem.dig("changes", "upgrade_count")
    assert_equal 1, mem.dig("changes", "downgrade_count")
  end

  test "product repurchase overdue counts reuse CrmCustomerProductCycle and compute week-over-week growth" do
    key = "wbtest_#{SecureRandom.hex(4)}"
    CrmProduct.create!(key: key, label: "週報測試品", status: "confirmed",
                        sql_pattern: "product_name LIKE '%週報測試品%'", regex_pattern: "週報測試品(\\d+)")

    # Already overdue at prev_week_end AND still overdue at week_end (started long ago, never repurchased).
    CrmCustomerProductCycle.create!(
      identity_key: "steady@example.com", email: "steady@example.com", product_key: key,
      cycle_started_at: @period.week_start - 200, bottle_count: 1, estimated_usage_days: 30,
      estimated_finish_date: @period.week_start - 170, suggested_contact_date: @period.week_start - 170,
      match_status: "not_yet_repurchased", refreshed_at: Time.current
    )
    # Became overdue only between prev_week_end and week_end (new this week).
    CrmCustomerProductCycle.create!(
      identity_key: "new_overdue@example.com", email: "new_overdue@example.com", product_key: key,
      cycle_started_at: @period.week_start - 40, bottle_count: 1, estimated_usage_days: 30,
      estimated_finish_date: @period.week_start + 2, suggested_contact_date: @period.week_start + 2,
      match_status: "not_yet_repurchased", refreshed_at: Time.current
    )

    product = WeeklyMetricsService.call(week_start: @week_start)["product_repurchase"]["products"].find { |p| p["product_key"] == key }

    assert_equal 2, product["overdue_count"]
    assert_equal 1, product["overdue_count_prev_week"]
  end

  test "revenue_progress handles a year with no prior-year data without dividing by zero" do
    make_order(email: "a@example.com", order_date: @period.week_start + 1.day, amount: 5000)

    rp = WeeklyMetricsService.call(week_start: @week_start)["revenue_progress"]

    assert_equal 5000.0, rp["this_week_revenue"]
    assert_equal 0.0, rp["last_year_full_year_revenue"]
    assert rp["already_beat_last_year"]
    assert_nothing_raised { rp["yoy_growth_pct"] }
  end

  test "order_quality computes failed and unpaid rates from payment_status" do
    make_order(email: "ok@example.com", order_date: @period.week_start + 1.day, amount: 100)
    make_order(email: "fail@example.com", order_date: @period.week_start + 1.day, amount: 100, payment_status: "付款失敗")

    oq = WeeklyMetricsService.call(week_start: @week_start)["order_quality"]
    assert_equal 50.0, oq["this_week_failed_rate_pct"]
  end
end

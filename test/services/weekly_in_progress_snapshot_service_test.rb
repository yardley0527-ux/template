# frozen_string_literal: true

require "test_helper"

class WeeklyInProgressSnapshotServiceTest < ActiveSupport::TestCase
  def make_order(email:, order_date:, amount:)
    ShoplineOrder.create!(order_number: "WIP#{SecureRandom.hex(6)}", email: email, product_name: "測試商品1",
                          order_date: order_date, payment_status: "已付款", quantity: 1, total_amount: amount)
  end

  test "compares the same number of elapsed days between this week and last week, not a partial week against a full one" do
    # 2026-06-16 is a Tuesday, day 2 of the week that starts 2026-06-15.
    today = Date.new(2026, 6, 16)
    period = WeeklyPeriod.new(today)
    prev_period = WeeklyPeriod.for_week_start(period.prev_week_start)

    # This week (days 1-2): 1000.
    make_order(email: "a@example.com", order_date: period.week_start, amount: 600)
    make_order(email: "a@example.com", order_date: today, amount: 400)
    # Last week's day 3-7 (should NOT be counted in the "same elapsed days" comparison).
    make_order(email: "b@example.com", order_date: prev_period.week_start + 3, amount: 9999)
    # Last week's day 1-2 (SHOULD be counted): 500.
    make_order(email: "b@example.com", order_date: prev_period.week_start, amount: 500)

    snapshot = WeeklyInProgressSnapshotService.call(reference_date: today)

    assert_equal 2, snapshot["days_elapsed"]
    assert_equal 5, snapshot["days_remaining"]
    assert_not snapshot["is_complete"]
    assert_equal 1000.0, snapshot.dig("this_week_partial", "revenue")
    assert_equal 500.0, snapshot.dig("prev_week_same_elapsed", "revenue"), "must only include the prior week's first 2 days, not its full 7 days"
    assert_equal 100.0, snapshot["revenue_growth_pct_same_elapsed"]
  end

  test "the full-week average for last week is still available for context, separate from the same-elapsed comparison" do
    today = Date.new(2026, 6, 16)
    period = WeeklyPeriod.new(today)
    prev_period = WeeklyPeriod.for_week_start(period.prev_week_start)

    (0..6).each { |offset| make_order(email: "full#{offset}@example.com", order_date: prev_period.week_start + offset, amount: 700) }

    snapshot = WeeklyInProgressSnapshotService.call(reference_date: today)

    assert_equal 4900.0, snapshot.dig("prev_week_full", "revenue")
    assert_equal 700.0, snapshot["daily_avg_prev_week_full"]
  end

  test "projects the full week using the current daily average, clearly labeled as an estimate" do
    today = Date.new(2026, 6, 16) # day 2
    period = WeeklyPeriod.new(today)
    make_order(email: "a@example.com", order_date: period.week_start, amount: 1000)
    make_order(email: "a@example.com", order_date: today, amount: 1000)

    snapshot = WeeklyInProgressSnapshotService.call(reference_date: today)

    assert_equal 1000.0, snapshot["daily_avg_this_week"]
    assert_equal 7000.0, snapshot["projected_full_week_revenue"]
    assert_includes snapshot["projection_note"], "推估"
  end

  test "days_elapsed is capped at 7 on the last day of the week" do
    sunday = Date.new(2026, 6, 21) # last day of the 06/15 week
    snapshot = WeeklyInProgressSnapshotService.call(reference_date: sunday)

    assert_equal 7, snapshot["days_elapsed"]
    assert_equal 0, snapshot["days_remaining"]
  end
end

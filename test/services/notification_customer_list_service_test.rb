# frozen_string_literal: true

require "test_helper"

class NotificationCustomerListServiceTest < ActiveSupport::TestCase
  def build_notification(category:, metadata:)
    Notification.create!(
      notification_key: "test", kind: "opportunity", category: category, severity: "opportunity", priority: "P2",
      title: "t", deduplication_key: "test:#{SecureRandom.hex(4)}", status: "detected",
      first_detected_at: Time.current, last_detected_at: Time.current, metadata: metadata
    )
  end

  def customer(email:, membership_level: "一般")
    ShoplineCustomer.create!(email: email, membership_level: membership_level)
  end

  def count_queries
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA CACHE]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  # ── customer_runout ────────────────────────────────────────────────

  test "customer_runout: a candidate who has not repurchased the product is included" do
    CrmProduct.create!(key: "metabolism", label: "代謝錠", status: "confirmed", availability_status: "in_stock")
    customer(email: "a@example.com")
    CrmCustomerProductTracking.create!(
      email: "a@example.com", product_key: "metabolism", last_order_date: 20.days.ago.to_date,
      last_order_bottles: 1, expected_return_date: Date.current + 3, suggested_reminder_date: Date.current - 4,
      order_count: 1, total_bottles: 1, refreshed_at: Time.current
    )
    n = build_notification(category: "customer_runout", metadata: {
      "query" => { "product_key" => "metabolism", "expected_return_date_from" => (Date.current).to_s,
                   "expected_return_date_to" => (Date.current + 7).to_s }
    })

    rows = NotificationCustomerListService.call(n)
    assert_equal 1, rows.size
    assert_equal "a@example.com", rows.first[:email]
  end

  test "customer_runout: a live-recheck excludes a candidate who already repurchased the same product" do
    CrmProduct.create!(key: "metabolism", label: "代謝錠", status: "confirmed", availability_status: "in_stock")
    customer(email: "a@example.com")
    CrmCustomerProductTracking.create!(
      email: "a@example.com", product_key: "metabolism", last_order_date: 20.days.ago.to_date,
      last_order_bottles: 1, expected_return_date: Date.current + 3, suggested_reminder_date: Date.current - 4,
      order_count: 1, total_bottles: 1, refreshed_at: Time.current
    )
    # A fresh order the nightly rollup hasn't picked up yet — this is what "live recheck" must catch.
    ShoplineOrder.create!(product_name: "代謝錠2瓶", email: "a@example.com", order_date: 1.hour.ago, checkout_amount: 1000)

    n = build_notification(category: "customer_runout", metadata: {
      "query" => { "product_key" => "metabolism", "expected_return_date_from" => (Date.current).to_s,
                   "expected_return_date_to" => (Date.current + 7).to_s }
    })

    assert_empty NotificationCustomerListService.call(n)
  end

  test "customer_runout: an order for a DIFFERENT product does not count as a repurchase" do
    CrmProduct.create!(key: "metabolism", label: "代謝錠", status: "confirmed", availability_status: "in_stock")
    customer(email: "a@example.com")
    CrmCustomerProductTracking.create!(
      email: "a@example.com", product_key: "metabolism", last_order_date: 20.days.ago.to_date,
      last_order_bottles: 1, expected_return_date: Date.current + 3, suggested_reminder_date: Date.current - 4,
      order_count: 1, total_bottles: 1, refreshed_at: Time.current
    )
    ShoplineOrder.create!(product_name: "薑黃粉", email: "a@example.com", order_date: 1.hour.ago, checkout_amount: 1000)

    n = build_notification(category: "customer_runout", metadata: {
      "query" => { "product_key" => "metabolism", "expected_return_date_from" => (Date.current).to_s,
                   "expected_return_date_to" => (Date.current + 7).to_s }
    })

    assert_equal 1, NotificationCustomerListService.call(n).size
  end

  # ── customer_overdue ────────────────────────────────────────────────

  test "customer_overdue: re-derives candidates from the overdue day-window query" do
    CrmProduct.create!(key: "metabolism", label: "代謝錠", status: "confirmed", availability_status: "in_stock")
    customer(email: "a@example.com")
    CrmCustomerProductTracking.create!(
      email: "a@example.com", product_key: "metabolism", last_order_date: 40.days.ago.to_date,
      last_order_bottles: 1, expected_return_date: Date.current - 10, suggested_reminder_date: Date.current - 17,
      order_count: 1, total_bottles: 1, refreshed_at: Time.current
    )
    n = build_notification(category: "customer_overdue", metadata: {
      "query" => { "product_key" => "metabolism", "overdue_days_from" => 1, "overdue_days_to" => 60 }
    })

    assert_equal 1, NotificationCustomerListService.call(n).size
  end

  # ── high_spender_no_second ──────────────────────────────────────────

  test "high_spender_no_second: a live-recheck excludes a customer whose genuine second purchase just landed" do
    customer(email: "a@example.com")
    CustomerPurchaseSummary.create!(email: "a@example.com", identity_key: "a@example.com",
                                     first_amount: 12_000, first_date: 45.days.ago, first_series: "全能")
    # Fresh order 10 days after first purchase — genuine second purchase the cached summary hasn't caught up to.
    ShoplineOrder.create!(email: "a@example.com", order_date: 35.days.ago, checkout_amount: 5000)

    n = build_notification(category: "high_spender_no_second", metadata: {
      "query" => { "first_month" => 45.days.ago.strftime("%Y-%m"), "first_series" => "全能", "first_amount_gte" => 10_000 }
    })

    assert_empty NotificationCustomerListService.call(n)
  end

  test "high_spender_no_second: a same-day split order does not count as a genuine second purchase" do
    customer(email: "a@example.com")
    CustomerPurchaseSummary.create!(email: "a@example.com", identity_key: "a@example.com",
                                     first_amount: 12_000, first_date: 45.days.ago, first_series: "全能")
    ShoplineOrder.create!(email: "a@example.com", order_date: 44.days.ago, checkout_amount: 500)

    n = build_notification(category: "high_spender_no_second", metadata: {
      "query" => { "first_month" => 45.days.ago.strftime("%Y-%m"), "first_series" => "全能", "first_amount_gte" => 10_000 }
    })

    assert_equal 1, NotificationCustomerListService.call(n).size
  end

  test "high_spender_no_second: the 未分類 fallback series maps back to null/blank, not a literal string match" do
    customer(email: "a@example.com")
    CustomerPurchaseSummary.create!(email: "a@example.com", identity_key: "a@example.com",
                                     first_amount: 12_000, first_date: 45.days.ago, first_series: nil)

    n = build_notification(category: "high_spender_no_second", metadata: {
      "query" => { "first_month" => 45.days.ago.strftime("%Y-%m"), "first_series" => "未分類", "first_amount_gte" => 10_000 }
    })

    assert_equal 1, NotificationCustomerListService.call(n).size
  end

  # ── vip_silent ──────────────────────────────────────────────────────

  test "vip_silent: a live-recheck excludes a VIP who has already come back" do
    customer(email: "a@example.com", membership_level: "金卡")
    CustomerPurchaseSummary.create!(email: "a@example.com", identity_key: "a@example.com",
                                     last_order_date: 100.days.ago, first_amount: 1000)
    ShoplineOrder.create!(email: "a@example.com", order_date: 1.hour.ago, checkout_amount: 500)

    n = build_notification(category: "vip_silent", metadata: {
      "query" => { "membership_level_in" => %w[黑卡 金卡], "silent_days_from" => 90, "silent_days_to" => 179 }
    })

    assert_empty NotificationCustomerListService.call(n)
  end

  test "vip_silent: a genuinely-still-silent VIP is included" do
    customer(email: "a@example.com", membership_level: "金卡")
    CustomerPurchaseSummary.create!(email: "a@example.com", identity_key: "a@example.com",
                                     last_order_date: 100.days.ago, first_amount: 1000)

    n = build_notification(category: "vip_silent", metadata: {
      "query" => { "membership_level_in" => %w[黑卡 金卡], "silent_days_from" => 90, "silent_days_to" => 179 }
    })

    assert_equal 1, NotificationCustomerListService.call(n).size
  end

  # ── query efficiency (no N+1 customer lookups) ──────────────────────

  test "customer_runout batches customer lookups instead of querying once per row" do
    CrmProduct.create!(key: "metabolism", label: "代謝錠", status: "confirmed", availability_status: "in_stock")
    3.times do |i|
      customer(email: "runout#{i}@example.com")
      CrmCustomerProductTracking.create!(
        email: "runout#{i}@example.com", product_key: "metabolism", last_order_date: 20.days.ago.to_date,
        last_order_bottles: 1, expected_return_date: Date.current + 3, suggested_reminder_date: Date.current - 4,
        order_count: 1, total_bottles: 1, refreshed_at: Time.current
      )
    end
    n = build_notification(category: "customer_runout", metadata: {
      "query" => { "product_key" => "metabolism", "expected_return_date_from" => Date.current.to_s,
                   "expected_return_date_to" => (Date.current + 7).to_s }
    })

    query_count = count_queries { NotificationCustomerListService.call(n) }
    # 1 tracking-row query + 1 batched customer query + (up to 3) live-recheck existence
    # queries — must NOT scale with an extra ShoplineCustomer query per row.
    assert_operator query_count, :<, 8, "expected a small, row-count-independent number of queries, got #{query_count}"
  end

  test "an unrecognized category returns an empty list rather than raising" do
    n = build_notification(category: "system_health", metadata: {})
    assert_equal [], NotificationCustomerListService.call(n)
  end
end

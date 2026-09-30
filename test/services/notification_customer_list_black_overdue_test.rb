# frozen_string_literal: true

require "test_helper"

class NotificationCustomerListBlackOverdueTest < ActiveSupport::TestCase
  def build_notification
    Notification.create!(
      notification_key: "black_overdue_metabolism", kind: "opportunity", category: "black_overdue",
      severity: "warning", priority: "P2", title: "t", deduplication_key: "test:#{SecureRandom.hex(4)}",
      status: "detected", first_detected_at: Time.current, last_detected_at: Time.current,
      metadata: { "query" => { "product_key" => "metabolism", "overdue_days_from" => 1, "overdue_days_to" => 60,
                               "membership_level_in" => %w[黑卡] } }
    )
  end

  def customer(email:, membership_level: "黑卡", total_amount: 10_000, instagram_account: nil)
    ShoplineCustomer.create!(email: email, membership_level: membership_level, total_amount: total_amount,
                             instagram_account: instagram_account, full_name: email.split("@").first)
  end

  def track(email:, overdue_days: 10)
    CrmCustomerProductTracking.create!(
      email: email, product_key: "metabolism", last_order_date: 90.days.ago.to_date, last_order_bottles: 1,
      expected_return_date: Date.current - overdue_days, suggested_reminder_date: Date.current - overdue_days - 7,
      order_count: 1, total_bottles: 6, refreshed_at: Time.current
    )
  end

  test "lists only black-card customers, highest cumulative spend first, with spend / IG / overdue days" do
    customer(email: "small@example.com", total_amount: 20_000, instagram_account: "small_ig")
    customer(email: "big@example.com", total_amount: 300_000, instagram_account: "@big_ig")
    customer(email: "gold@example.com", membership_level: "金卡", total_amount: 999_999)
    %w[small big gold].each { |n| track(email: "#{n}@example.com", overdue_days: 12) }

    rows = NotificationCustomerListService.call(build_notification)

    assert_equal %w[big@example.com small@example.com], rows.map { |r| r[:email] }
    assert_equal [300_000, 20_000], rows.map { |r| r[:total_amount] }
    assert_equal "@big_ig", rows.first[:instagram_account]
    assert_equal 12, rows.first[:overdue_days]
  end

  test "a black-card customer who already repurchased the product since the last order drops out" do
    customer(email: "back@example.com")
    track(email: "back@example.com")
    CrmProduct.create!(key: "metabolism", label: "代謝錠", status: "confirmed", availability_status: "in_stock",
                       sql_pattern: "product_name LIKE '%代謝錠%'")
    ShoplineOrder.create!(email: "back@example.com", order_date: 1.day.ago, product_name: "比利時超代謝精華錠 代謝錠", checkout_amount: 2880)

    assert_empty NotificationCustomerListService.call(build_notification)
  end

  test "black-card customers are not crowded out by earlier-overdue non-black customers when the result limit is hit" do
    3.times do |i|
      customer(email: "regular#{i}@example.com", membership_level: "一般")
      track(email: "regular#{i}@example.com", overdue_days: 50)
    end
    customer(email: "black@example.com")
    track(email: "black@example.com", overdue_days: 5)

    rows = with_result_limit(2) { NotificationCustomerListService.call(build_notification) }

    assert_equal %w[black@example.com], rows.map { |r| r[:email] }
  end

  private

  def with_result_limit(limit)
    klass = NotificationCustomerListService
    original = klass::RESULT_LIMIT
    klass.send(:remove_const, :RESULT_LIMIT)
    klass.const_set(:RESULT_LIMIT, limit)
    yield
  ensure
    klass.send(:remove_const, :RESULT_LIMIT)
    klass.const_set(:RESULT_LIMIT, original)
  end
end

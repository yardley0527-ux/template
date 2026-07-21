# frozen_string_literal: true

require "test_helper"

module NotificationRules
  class EventAttentionTest < ActiveSupport::TestCase
    def taipei_order(date:, hour: 12, checkout_amount:)
      time = ActiveSupport::TimeZone["Asia/Taipei"].local(date.year, date.month, date.day, hour, 0, 0)
      ShoplineOrder.create!(order_number: SecureRandom.hex(6), order_date: time, checkout_amount: checkout_amount)
    end

    def livestream(date:, window_days: 0)
      Livestream.create!(date: date, window_days: window_days)
    end

    # window_days: 0 keeps each livestream's attribution window to exactly its own day,
    # so orders placed on other livestreams' days never leak into each other's revenue.

    test "T-3 countdown fires when a livestream calendar event exists 3 days out" do
      CalendarEvent.create!(title: "夏日場", event_type: "livestream", event_date: Date.current + 3)

      result = EventAttention.call.find { |r| r[:notification_key] == "event_countdown_t3" }
      assert result.present?
      assert_equal "info", result[:severity]
      assert_includes result[:title], "夏日場"
    end

    test "T-1 countdown fires independently of T-3" do
      CalendarEvent.create!(title: "夏日場", event_type: "livestream", event_date: Date.current + 1)

      result = EventAttention.call.find { |r| r[:notification_key] == "event_countdown_t1" }
      assert result.present?
    end

    test "no countdown fires when no livestream event falls on T-3 or T-1" do
      CalendarEvent.create!(title: "夏日場", event_type: "livestream", event_date: Date.current + 5)

      assert_empty EventAttention.call.select { |r| r[:notification_key]&.start_with?("event_countdown") }
    end

    test "a non-livestream event on T-3 does not trigger the countdown" do
      CalendarEvent.create!(title: "中元節", event_type: "holiday", event_date: Date.current + 3)

      assert_empty EventAttention.call.select { |r| r[:notification_key]&.start_with?("event_countdown") }
    end

    test "fewer than 4 livestreams on record produces no D+4 comparison" do
      3.times { |i| livestream(date: (i + 1).days.ago.to_date) }

      assert_empty EventAttention.call.select { |r| r[:notification_key] == "event_d4_weak" }
    end

    test "a latest livestream far below the prior 3-livestream average is flagged weak" do
      [40, 30, 20, 10].each { |days_ago| livestream(date: days_ago.days.ago.to_date) }
      # prior 3 (40/30/20 days ago) average 10,000; latest (10 days ago) far below 50%
      [40, 30, 20].each { |days_ago| taipei_order(date: days_ago.days.ago.to_date, checkout_amount: 10_000) }
      taipei_order(date: 10.days.ago.to_date, checkout_amount: 1_000)

      result = EventAttention.call.find { |r| r[:notification_key] == "event_d4_weak" }
      assert result.present?
      assert_equal "warning", result[:severity]
      assert_equal 1_000, result[:metadata][:revenue]
      assert_equal 10_000, result[:metadata][:prior_avg_revenue]
    end

    test "a latest livestream at or above 50% of the prior average is not flagged" do
      [40, 30, 20, 10].each { |days_ago| livestream(date: days_ago.days.ago.to_date) }
      [40, 30, 20].each { |days_ago| taipei_order(date: days_ago.days.ago.to_date, checkout_amount: 10_000) }
      taipei_order(date: 10.days.ago.to_date, checkout_amount: 6_000)

      assert_empty EventAttention.call.select { |r| r[:notification_key] == "event_d4_weak" }
    end

    test "a zero prior average never divides by zero, just skips" do
      [40, 30, 20, 10].each { |days_ago| livestream(date: days_ago.days.ago.to_date) }
      taipei_order(date: 10.days.ago.to_date, checkout_amount: 5_000)

      assert_nothing_raised { EventAttention.call }
      assert_empty EventAttention.call.select { |r| r[:notification_key] == "event_d4_weak" }
    end

    test "no events and no livestreams produces no cards" do
      assert_empty EventAttention.call
    end
  end
end

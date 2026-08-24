# frozen_string_literal: true

require "test_helper"

module NotificationRules
  class LivestreamDayAttentionTest < ActiveSupport::TestCase
    test "no card when nothing is scheduled today" do
      assert_empty LivestreamDayAttention.call
    end

    test "P3 info card when a livestream is scheduled today, even with no order data yet" do
      CalendarEvent.create!(title: "膠原直播", event_type: "livestream", event_date: Date.current)

      result = LivestreamDayAttention.call
      assert_equal 1, result.size
      assert_equal "P3", result.first[:priority]
      assert_equal "info", result.first[:severity]
      assert_includes result.first[:message], "尚未有訂單資料"
    end

    test "summarizes real revenue/orders/buyers once a Livestream row with orders exists" do
      CalendarEvent.create!(title: "膠原直播", event_type: "livestream", event_date: Date.current)
      Livestream.create!(date: Date.current, product_keys: ["collagen"])
      ShoplineOrder.create!(product_name: "膠原蛋白6", email: "a@example.com", order_date: Time.current,
                            checkout_amount: 17600, order_number: "1")

      result = LivestreamDayAttention.call.first
      assert_equal 17600, result[:metadata][:revenue]
      assert_equal 1, result[:metadata][:orders]
      assert_equal 1, result[:metadata][:buyers]
    end

    test "never produces a P0/P1 — no target field exists, so this is always informational" do
      CalendarEvent.create!(title: "膠原直播", event_type: "livestream", event_date: Date.current)
      Livestream.create!(date: Date.current)

      result = LivestreamDayAttention.call.first
      assert_not_includes %w[P0 P1], result[:priority]
    end
  end
end

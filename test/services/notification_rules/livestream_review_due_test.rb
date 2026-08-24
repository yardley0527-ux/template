# frozen_string_literal: true

require "test_helper"

module NotificationRules
  class LivestreamReviewDueTest < ActiveSupport::TestCase
    test "no card before D+3" do
      Livestream.create!(date: 2.days.ago.to_date)
      assert_empty LivestreamReviewDue.call
    end

    test "P2 at exactly D+3 unreviewed" do
      Livestream.create!(date: 3.days.ago.to_date)
      result = LivestreamReviewDue.call
      assert_equal 1, result.size
      assert_equal "P2", result.first[:priority]
    end

    test "P1 at D+5 or later unreviewed" do
      Livestream.create!(date: 5.days.ago.to_date)
      assert_equal "P1", LivestreamReviewDue.call.first[:priority]
    end

    test "no card once review_completed_at is set" do
      Livestream.create!(date: 5.days.ago.to_date, review_completed_at: Time.current)
      assert_empty LivestreamReviewDue.call
    end

    test "old livestreams beyond the lookback window stop nagging" do
      Livestream.create!(date: 90.days.ago.to_date)
      assert_empty LivestreamReviewDue.call
    end

    test "auto-computed metadata includes revenue/orders/buyers so nobody has to retype it" do
      ls = Livestream.create!(date: 3.days.ago.to_date)
      ShoplineOrder.create!(product_name: "膠原蛋白6", email: "a@example.com", order_date: ls.date,
                            checkout_amount: 17600, order_number: "1")

      result = LivestreamReviewDue.call.first
      assert_equal 17600, result[:metadata][:revenue]
    end
  end
end

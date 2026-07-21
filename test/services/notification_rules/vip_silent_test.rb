# frozen_string_literal: true

require "test_helper"

module NotificationRules
  class VipSilentTest < ActiveSupport::TestCase
    def vip(email:, membership_level:, last_order_date:)
      ShoplineCustomer.create!(email: email, membership_level: membership_level)
      CustomerPurchaseSummary.create!(
        email: email, identity_key: email.downcase, last_order_date: last_order_date,
        first_amount: 1000, silent_only: true
      )
    end

    test "black/gold card customers silent 90-179 days land in the opportunity tier" do
      vip(email: "gold@example.com", membership_level: "金卡", last_order_date: 100.days.ago)

      card = VipSilent.call.find { |r| r[:metadata][:tier] == "90_179" }
      assert card.present?
      assert_equal "opportunity", card[:severity]
      assert_equal 1, card[:metadata][:count]
      assert_equal 1, card[:metadata][:gold_count]
      assert_equal 0, card[:metadata][:black_count]
    end

    test "silent 180+ days lands in the warning tier, never critical" do
      vip(email: "black@example.com", membership_level: "黑卡", last_order_date: 200.days.ago)

      card = VipSilent.call.find { |r| r[:metadata][:tier] == "180_plus" }
      assert card.present?
      assert_equal "warning", card[:severity]
      assert_equal 1, card[:metadata][:black_count]
    end

    test "regular (non black/gold) members are never included regardless of silence" do
      vip(email: "regular@example.com", membership_level: "一般", last_order_date: 200.days.ago)

      assert_empty VipSilent.call
    end

    test "silent under 90 days does not qualify for either tier" do
      vip(email: "recent@example.com", membership_level: "金卡", last_order_date: 30.days.ago)

      assert_empty VipSilent.call
    end

    test "aggregates multiple silent VIPs into one card per tier, not one per customer" do
      vip(email: "a@example.com", membership_level: "金卡", last_order_date: 100.days.ago)
      vip(email: "b@example.com", membership_level: "黑卡", last_order_date: 120.days.ago)

      results = VipSilent.call.select { |r| r[:metadata][:tier] == "90_179" }
      assert_equal 1, results.size, "must be one card for the tier, not one per customer"
      assert_equal 2, results.first[:metadata][:count]
    end

    test "deduplication_key cycles weekly so a persisting silence naturally reopens across weeks" do
      vip(email: "a@example.com", membership_level: "金卡", last_order_date: 100.days.ago)
      key_this_week = VipSilent.call.find { |r| r[:metadata][:tier] == "90_179" }[:deduplication_key]

      travel 8.days do
        key_next_week = VipSilent.call.find { |r| r[:metadata][:tier] == "90_179" }[:deduplication_key]
        assert_not_equal key_this_week, key_next_week
      end
    end

    test "no email appears in metadata (PII safety)" do
      vip(email: "leak-me@example.com", membership_level: "金卡", last_order_date: 100.days.ago)

      result = VipSilent.call.find { |r| r[:metadata][:tier] == "90_179" }
      assert_not_includes result[:metadata].to_s, "leak-me@example.com"
    end

    test "no silent VIPs produces no cards" do
      assert_empty VipSilent.call
    end
  end
end

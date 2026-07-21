# frozen_string_literal: true

require "test_helper"

module NotificationRules
  class HighSpenderNoSecondTest < ActiveSupport::TestCase
    def summary(email:, first_amount:, first_date:, series: "全能", purchase_count: 1, second_date: nil)
      CustomerPurchaseSummary.create!(
        email: email, identity_key: email.downcase, first_amount: first_amount, first_date: first_date,
        first_series: series, purchase_count: purchase_count, second_date: second_date, silent_only: true
      )
    end

    def customer(email:, line_id: nil)
      ShoplineCustomer.create!(email: email, line_id: line_id)
    end

    test "aggregates first-time high spenders with no genuine second purchase into one card per month+series" do
      customer(email: "a@example.com", line_id: "line-a")
      customer(email: "b@example.com")
      summary(email: "a@example.com", first_amount: 12_000, first_date: 45.days.ago)
      summary(email: "b@example.com", first_amount: 15_000, first_date: 40.days.ago)

      results = HighSpenderNoSecond.call
      assert_equal 1, results.size, "must be one aggregate card, not one per customer"

      card = results.first
      assert_equal 2, card[:metadata][:count]
      assert_equal 1, card[:metadata][:contactable_line_id_count], "only the line_id-having customer counts as contactable"
      assert_equal 27_000, card[:metadata][:first_amount_sum]
    end

    test "below the 10,000 threshold does not qualify" do
      customer(email: "a@example.com")
      summary(email: "a@example.com", first_amount: 9_999, first_date: 45.days.ago)

      assert_empty HighSpenderNoSecond.call
    end

    test "outside the 30-90 day window does not qualify" do
      customer(email: "a@example.com")
      summary(email: "a@example.com", first_amount: 12_000, first_date: 10.days.ago)

      assert_empty HighSpenderNoSecond.call
    end

    test "a genuine second purchase 7+ days after the first excludes the customer" do
      customer(email: "a@example.com")
      summary(email: "a@example.com", first_amount: 12_000, first_date: 45.days.ago,
              purchase_count: 2, second_date: 38.days.ago)

      assert_empty HighSpenderNoSecond.call
    end

    test "a same-day split order (second_date within 7 days) does not count as a real second purchase" do
      customer(email: "a@example.com")
      summary(email: "a@example.com", first_amount: 12_000, first_date: 45.days.ago,
              purchase_count: 2, second_date: 44.days.ago)

      assert_equal 1, HighSpenderNoSecond.call.size, "split order must still be treated as no-second-purchase"
    end

    test "no email appears in metadata (PII safety)" do
      customer(email: "leak-me@example.com")
      summary(email: "leak-me@example.com", first_amount: 12_000, first_date: 45.days.ago)

      result = HighSpenderNoSecond.call.first
      assert_not_includes result[:metadata].to_s, "leak-me@example.com"
    end

    test "no qualifying rows produces no card" do
      assert_empty HighSpenderNoSecond.call
    end
  end
end

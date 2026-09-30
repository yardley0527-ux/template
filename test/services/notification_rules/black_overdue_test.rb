# frozen_string_literal: true

require "test_helper"

module NotificationRules
  class BlackOverdueTest < ActiveSupport::TestCase
    def customer(email:, membership_level: "黑卡", total_amount: 50_000)
      ShoplineCustomer.create!(email: email, membership_level: membership_level, total_amount: total_amount)
    end

    def track(product_key:, email:, overdue_days:)
      CrmCustomerProductTracking.create!(
        email: email, product_key: product_key, last_order_date: 90.days.ago.to_date,
        last_order_bottles: 1, expected_return_date: Date.current - overdue_days,
        suggested_reminder_date: Date.current - overdue_days - 7,
        order_count: 1, total_bottles: 1, refreshed_at: Time.current
      )
    end

    def card_for(product_key)
      BlackOverdue.call.find { |r| r[:subject_id] == product_key }
    end

    test "one card per product counting only black-card customers overdue 1-60 days" do
      customer(email: "black@example.com")
      customer(email: "gold@example.com", membership_level: "金卡")
      customer(email: "regular@example.com", membership_level: "一般")
      %w[black gold regular].each { |n| track(product_key: "metabolism", email: "#{n}@example.com", overdue_days: 20) }

      card = card_for("metabolism")

      assert card.present?
      assert_equal 1, card[:metadata][:total_count], "only the black-card customer counts"
      assert_equal "black_overdue", card[:notification_key].sub(/_metabolism\z/, "")
      assert_includes card[:title], "黑卡逾期未回購"
      assert_equal %w[黑卡], card[:metadata][:query][:membership_level_in]
    end

    test "not yet overdue and overdue beyond 60 days are excluded" do
      customer(email: "fresh@example.com")
      customer(email: "cold@example.com")
      track(product_key: "metabolism", email: "fresh@example.com", overdue_days: 0)
      track(product_key: "metabolism", email: "cold@example.com", overdue_days: 61)

      assert_nil card_for("metabolism")
    end

    test "glutathione is excluded entirely (wave-restock product)" do
      customer(email: "black@example.com")
      track(product_key: "glutathione", email: "black@example.com", overdue_days: 10)

      assert_nil card_for("glutathione")
    end

    test "out-of-stock products do not produce a card" do
      CrmProduct.create!(key: "metabolism", label: "代謝錠", status: "confirmed", availability_status: "out_of_stock")
      customer(email: "black@example.com")
      track(product_key: "metabolism", email: "black@example.com", overdue_days: 10)

      assert_nil card_for("metabolism")
    end

    test "the same customer overdue on two products shows up once per product card" do
      customer(email: "black@example.com")
      track(product_key: "metabolism", email: "black@example.com", overdue_days: 10)
      track(product_key: "probiotic", email: "black@example.com", overdue_days: 10)

      assert_equal 1, card_for("metabolism")[:metadata][:total_count]
      assert_equal 1, card_for("probiotic")[:metadata][:total_count]
    end

    test "deduplication key is stable per product so a persisting condition stays one open card" do
      customer(email: "black@example.com")
      track(product_key: "metabolism", email: "black@example.com", overdue_days: 10)

      assert_equal "black_overdue:journey_product:metabolism", card_for("metabolism")[:deduplication_key]
    end

    test "no email appears in the card (PII safety)" do
      customer(email: "leak-me@example.com")
      track(product_key: "metabolism", email: "leak-me@example.com", overdue_days: 10)

      assert_not_includes card_for("metabolism").to_s, "leak-me@example.com"
    end
  end
end

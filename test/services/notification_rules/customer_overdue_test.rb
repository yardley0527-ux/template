# frozen_string_literal: true

require "test_helper"

module NotificationRules
  class CustomerOverdueTest < ActiveSupport::TestCase
    def customer(email:, membership_level: "金卡")
      ShoplineCustomer.create!(email: email, membership_level: membership_level)
    end

    def track(product_key:, email:, overdue_days:, bottles: 1)
      CrmCustomerProductTracking.create!(
        email: email, product_key: product_key, last_order_date: 60.days.ago.to_date,
        last_order_bottles: bottles, expected_return_date: Date.current - overdue_days,
        suggested_reminder_date: Date.current - overdue_days - 7,
        order_count: 1, total_bottles: bottles, refreshed_at: Time.current
      )
    end

    test "aggregates only high-value overdue customers into the card; general customers are excluded" do
      customer(email: "gold@example.com", membership_level: "金卡")
      customer(email: "regular@example.com", membership_level: "一般")
      track(product_key: "metabolism", email: "gold@example.com", overdue_days: 10)
      track(product_key: "metabolism", email: "regular@example.com", overdue_days: 10)

      result = CustomerOverdue.call.find { |r| r[:subject_id] == "metabolism" }

      assert result.present?
      assert_equal 1, result[:metadata][:total_count], "only the high-value customer counts toward the maintained list"
      assert_equal 1, result[:metadata][:high_value_count]
      assert_equal 1, result[:metadata][:general_count], "general customer still tracked in metadata, just not surfaced"
      assert_equal "warning", result[:severity]
      assert_includes result[:title], "高價值"
      assert_not_includes result[:title], "regular@example.com"
    end

    test "a general-tier customer whose last order was a big set (bottles >= threshold) counts as high-value" do
      customer(email: "bigset@example.com", membership_level: "一般")
      track(product_key: "metabolism", email: "bigset@example.com", overdue_days: 10, bottles: 6)

      result = CustomerOverdue.call.find { |r| r[:subject_id] == "metabolism" }
      assert result.present?
      assert_equal 1, result[:metadata][:high_value_count]
    end

    test "a general-tier customer whose last order was below the big-set threshold stays excluded" do
      customer(email: "smallset@example.com", membership_level: "一般")
      track(product_key: "metabolism", email: "smallset@example.com", overdue_days: 10, bottles: 5)

      assert_empty CustomerOverdue.call.select { |r| r[:subject_id] == "metabolism" }
    end

    test "no high-value customer produces no card at all" do
      customer(email: "regular@example.com", membership_level: "一般")
      track(product_key: "metabolism", email: "regular@example.com", overdue_days: 10)

      assert_empty CustomerOverdue.call.select { |r| r[:subject_id] == "metabolism" }
    end

    test "glutathione is excluded entirely regardless of overdue rows" do
      customer(email: "a@example.com")
      track(product_key: "glutathione", email: "a@example.com", overdue_days: 10)

      assert_empty CustomerOverdue.call.select { |r| r[:subject_id] == "glutathione" }
    end

    test "qingxian and simi are tagged as estimated-cycle in metadata and title" do
      customer(email: "a@example.com")
      track(product_key: "qingxian", email: "a@example.com", overdue_days: 10)

      result = CustomerOverdue.call.find { |r| r[:subject_id] == "qingxian" }
      assert result[:metadata][:estimated_cycle]
      assert_includes result[:title], "估計值"
    end

    test "a product with no rows outside the excluded list is not tagged estimated-cycle" do
      customer(email: "a@example.com")
      track(product_key: "metabolism", email: "a@example.com", overdue_days: 10)

      result = CustomerOverdue.call.find { |r| r[:subject_id] == "metabolism" }
      assert_not result[:metadata][:estimated_cycle]
    end

    test "discontinued product is excluded from customer_overdue" do
      CrmProduct.create!(key: "metabolism", label: "代謝錠", status: "confirmed", availability_status: "discontinued")
      customer(email: "a@example.com")
      track(product_key: "metabolism", email: "a@example.com", overdue_days: 10)

      assert_empty CustomerOverdue.call.select { |r| r[:subject_id] == "metabolism" }
    end

    test "no email or phone appears in metadata (PII safety)" do
      customer(email: "leak-me@example.com")
      track(product_key: "metabolism", email: "leak-me@example.com", overdue_days: 10)

      result = CustomerOverdue.call.find { |r| r[:subject_id] == "metabolism" }
      assert_not_includes result[:metadata].to_s, "leak-me@example.com"
    end

    test "no rows produces no card" do
      assert_empty CustomerOverdue.call
    end
  end
end

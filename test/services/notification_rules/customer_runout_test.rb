# frozen_string_literal: true

require "test_helper"

module NotificationRules
  class CustomerRunoutTest < ActiveSupport::TestCase
    def track(product_key:, email:, days_until_runout:)
      CrmCustomerProductTracking.create!(
        email: email, product_key: product_key, last_order_date: 30.days.ago.to_date,
        last_order_bottles: 1, expected_return_date: Date.current + days_until_runout,
        suggested_reminder_date: Date.current + days_until_runout - 7,
        order_count: 1, total_bottles: 1, refreshed_at: Time.current
      )
    end

    test "aggregates customers within 0-7 days into a single card per product, not one per customer" do
      3.times { |i| track(product_key: "metabolism", email: "run#{i}@example.com", days_until_runout: 5) }

      results = CustomerRunout.call
      metabolism = results.find { |r| r[:subject_id] == "metabolism" }

      assert metabolism.present?
      assert_equal 1, results.count { |r| r[:subject_id] == "metabolism" }, "must be exactly one card, not 3"
      assert_equal 3, metabolism[:metadata][:count]
    end

    test "8-14 day customers are not their own notification, only a preview count in metadata" do
      track(product_key: "metabolism", email: "a@example.com", days_until_runout: 5)
      track(product_key: "metabolism", email: "b@example.com", days_until_runout: 10)

      results = CustomerRunout.call
      metabolism_results = results.select { |r| r[:subject_id] == "metabolism" }

      assert_equal 1, metabolism_results.size
      assert_equal 1, metabolism_results.first[:metadata][:runout_8_14_preview_count]
    end

    test "out_of_stock product does not generate a runout card" do
      CrmProduct.create!(key: "metabolism", label: "代謝錠", status: "confirmed", availability_status: "out_of_stock")
      track(product_key: "metabolism", email: "a@example.com", days_until_runout: 5)

      assert_empty CustomerRunout.call.select { |r| r[:subject_id] == "metabolism" }
    end

    test "preorder product generates a card tagged 預購中" do
      CrmProduct.create!(key: "metabolism", label: "代謝錠", status: "confirmed", availability_status: "preorder")
      track(product_key: "metabolism", email: "a@example.com", days_until_runout: 5)

      result = CustomerRunout.call.find { |r| r[:subject_id] == "metabolism" }
      assert result.present?
      assert_includes result[:title], "預購中"
    end

    test "qingxian tracking rows check availability via the cleanse_powder crm_product (key mapping)" do
      CrmProduct.create!(key: "cleanse_powder", label: "清纖粉", status: "confirmed", availability_status: "out_of_stock")
      track(product_key: "qingxian", email: "a@example.com", days_until_runout: 5)

      assert_empty CustomerRunout.call.select { |r| r[:subject_id] == "qingxian" },
        "qingxian must resolve to cleanse_powder's status, not silently skip the lookup"
    end

    test "no email appears in metadata (PII safety)" do
      track(product_key: "metabolism", email: "leak-me@example.com", days_until_runout: 5)

      result = CustomerRunout.call.find { |r| r[:subject_id] == "metabolism" }
      assert_not_includes result[:metadata].to_s, "leak-me@example.com"
    end

    test "product with no rows within the window produces no card" do
      assert_empty CustomerRunout.call
    end

    test "deduplication_key is stable per product, not per run" do
      track(product_key: "metabolism", email: "a@example.com", days_until_runout: 5)
      first = CustomerRunout.call.find { |r| r[:subject_id] == "metabolism" }[:deduplication_key]
      second = CustomerRunout.call.find { |r| r[:subject_id] == "metabolism" }[:deduplication_key]
      assert_equal first, second
    end
  end
end

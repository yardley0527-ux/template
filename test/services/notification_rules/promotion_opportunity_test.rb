# frozen_string_literal: true

require "test_helper"

module NotificationRules
  class PromotionOpportunityTest < ActiveSupport::TestCase
    def customer(email:)
      ShoplineCustomer.create!(email: email, membership_level: "一般")
    end

    def track(product_key:, email:, overdue_days:)
      CrmCustomerProductTracking.create!(
        email: email, product_key: product_key, last_order_date: 60.days.ago.to_date,
        last_order_bottles: 1, expected_return_date: Date.current - overdue_days,
        suggested_reminder_date: Date.current - overdue_days - 7,
        order_count: 1, total_bottles: 1, refreshed_at: Time.current
      )
    end

    def snapshot(product_key:, discount_pct:, scraped_at: Time.current)
      ProductPromotionSnapshot.create!(
        product_key: product_key, product_name: "測試商品", product_url: "https://www.yardley.tw/products/x",
        regular_price: 1000, sale_price: (1000 * (1 - discount_pct / 100.0)).round,
        discount_pct: discount_pct, scraped_at: scraped_at
      )
    end

    test "fires when the latest snapshot is discounted and there is no prior snapshot" do
      customer(email: "a@example.com")
      track(product_key: "probiotic", email: "a@example.com", overdue_days: 10)
      snapshot(product_key: "probiotic", discount_pct: 25.0)

      result = PromotionOpportunity.call.find { |r| r[:subject_id] == "probiotic" }

      assert result.present?
      assert_equal 1, result[:metadata][:count]
      assert_equal 25.0, result[:metadata][:discount_pct]
      assert_includes result[:title], "25.0%"
    end

    test "does not fire when the prior snapshot was already discounted (not newly discounted)" do
      customer(email: "a@example.com")
      track(product_key: "probiotic", email: "a@example.com", overdue_days: 10)
      snapshot(product_key: "probiotic", discount_pct: 25.0, scraped_at: 1.day.ago)
      snapshot(product_key: "probiotic", discount_pct: 30.0, scraped_at: Time.current)

      assert_empty PromotionOpportunity.call.select { |r| r[:subject_id] == "probiotic" }
    end

    test "does not fire when the latest snapshot has no discount" do
      customer(email: "a@example.com")
      track(product_key: "probiotic", email: "a@example.com", overdue_days: 10)
      snapshot(product_key: "probiotic", discount_pct: 0.0)

      assert_empty PromotionOpportunity.call.select { |r| r[:subject_id] == "probiotic" }
    end

    test "fires again once a discount lapses and a new one starts" do
      customer(email: "a@example.com")
      track(product_key: "probiotic", email: "a@example.com", overdue_days: 10)
      snapshot(product_key: "probiotic", discount_pct: 25.0, scraped_at: 3.days.ago)
      snapshot(product_key: "probiotic", discount_pct: 0.0, scraped_at: 2.days.ago)
      snapshot(product_key: "probiotic", discount_pct: 15.0, scraped_at: Time.current)

      result = PromotionOpportunity.call.find { |r| r[:subject_id] == "probiotic" }
      assert result.present?
      assert_equal 15.0, result[:metadata][:discount_pct]
    end

    test "no tracking rows in the overdue window produces no card even with a fresh discount" do
      snapshot(product_key: "probiotic", discount_pct: 25.0)

      assert_empty PromotionOpportunity.call.select { |r| r[:subject_id] == "probiotic" }
    end

    test "discontinued product is excluded even with a fresh discount and overdue customers" do
      CrmProduct.create!(key: "probiotic", label: "益生菌", status: "confirmed", availability_status: "discontinued")
      customer(email: "a@example.com")
      track(product_key: "probiotic", email: "a@example.com", overdue_days: 10)
      snapshot(product_key: "probiotic", discount_pct: 25.0)

      assert_empty PromotionOpportunity.call.select { |r| r[:subject_id] == "probiotic" }
    end

    test "no email appears in metadata (PII safety)" do
      customer(email: "leak-me@example.com")
      track(product_key: "probiotic", email: "leak-me@example.com", overdue_days: 10)
      snapshot(product_key: "probiotic", discount_pct: 25.0)

      result = PromotionOpportunity.call.find { |r| r[:subject_id] == "probiotic" }
      assert_not_includes result[:metadata].to_s, "leak-me@example.com"
    end

    test "no snapshot at all produces no card" do
      customer(email: "a@example.com")
      track(product_key: "probiotic", email: "a@example.com", overdue_days: 10)

      assert_empty PromotionOpportunity.call
    end
  end
end

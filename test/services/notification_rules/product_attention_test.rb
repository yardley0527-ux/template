# frozen_string_literal: true

require "test_helper"

module NotificationRules
  class ProductAttentionTest < ActiveSupport::TestCase
    def crm_product(key:, availability_status: "in_stock")
      CrmProduct.create!(key: key, label: key, status: "confirmed", availability_status: availability_status)
    end

    def order(sql_key:, order_date:, checkout_amount:)
      ShoplineOrder.create!(product_name: sql_key, order_date: order_date, checkout_amount: checkout_amount)
    end

    # metabolism's real sql pattern (see JourneyProducts::PRODUCTS) matches product_name LIKE '%代謝%'
    def seed_weeks(sql_key:, this_week:, last_week:)
      order(sql_key: sql_key, order_date: 3.days.ago, checkout_amount: this_week) if this_week.positive?
      order(sql_key: sql_key, order_date: 10.days.ago, checkout_amount: last_week) if last_week.positive?
    end

    test "in_stock product with week-over-week growth above threshold surfaces an opportunity card" do
      crm_product(key: "metabolism", availability_status: "in_stock")
      seed_weeks(sql_key: "代謝錠", this_week: 20_000, last_week: 10_000)

      result = ProductAttention.call.find { |r| r[:subject_id] == "metabolism" }
      assert result.present?
      assert_equal "opportunity", result[:severity]
      assert_equal "opportunity", result[:kind]
      assert_includes result[:title], "成長"
    end

    test "in_stock product with a week-over-week drop above threshold surfaces an alert card" do
      crm_product(key: "metabolism", availability_status: "in_stock")
      seed_weeks(sql_key: "代謝錠", this_week: 2_000, last_week: 10_000)

      result = ProductAttention.call.find { |r| r[:subject_id] == "metabolism" }
      assert result.present?
      assert_equal "warning", result[:severity]
      assert_equal "alert", result[:kind]
      assert_includes result[:title], "下降"
    end

    test "a change within +/-50% does not surface a card" do
      crm_product(key: "metabolism", availability_status: "in_stock")
      seed_weeks(sql_key: "代謝錠", this_week: 11_000, last_week: 10_000)

      assert_empty ProductAttention.call.select { |r| r[:subject_id] == "metabolism" }
    end

    test "a prior-week baseline below the minimum floor is skipped to avoid a distorted percentage" do
      crm_product(key: "metabolism", availability_status: "in_stock")
      seed_weeks(sql_key: "代謝錠", this_week: 5_000, last_week: 100)

      assert_empty ProductAttention.call.select { |r| r[:subject_id] == "metabolism" }
    end

    test "unknown availability_status never produces a trend conclusion" do
      crm_product(key: "metabolism", availability_status: "unknown")
      seed_weeks(sql_key: "代謝錠", this_week: 20_000, last_week: 10_000)

      assert_empty ProductAttention.call.select { |r| r[:subject_id] == "metabolism" }
    end

    test "out_of_stock availability_status never produces a trend conclusion" do
      crm_product(key: "metabolism", availability_status: "out_of_stock")
      seed_weeks(sql_key: "代謝錠", this_week: 20_000, last_week: 10_000)

      assert_empty ProductAttention.call.select { |r| r[:subject_id] == "metabolism" }
    end

    test "a drop is suppressed when a livestream fell within the recent window" do
      crm_product(key: "metabolism", availability_status: "in_stock")
      seed_weeks(sql_key: "代謝錠", this_week: 2_000, last_week: 10_000)
      Livestream.create!(date: 2.days.ago.to_date)

      assert_empty ProductAttention.call.select { |r| r[:subject_id] == "metabolism" }
    end

    test "growth is NOT suppressed by a recent livestream, only drops are" do
      crm_product(key: "metabolism", availability_status: "in_stock")
      seed_weeks(sql_key: "代謝錠", this_week: 20_000, last_week: 10_000)
      Livestream.create!(date: 2.days.ago.to_date)

      result = ProductAttention.call.find { |r| r[:subject_id] == "metabolism" }
      assert result.present?
      assert_equal "opportunity", result[:severity]
    end

    test "at most one card per product" do
      crm_product(key: "metabolism", availability_status: "in_stock")
      seed_weeks(sql_key: "代謝錠", this_week: 20_000, last_week: 10_000)

      assert_equal 1, ProductAttention.call.count { |r| r[:subject_id] == "metabolism" }
    end

    test "no products with sufficient baseline data produces no cards" do
      assert_empty ProductAttention.call
    end
  end
end

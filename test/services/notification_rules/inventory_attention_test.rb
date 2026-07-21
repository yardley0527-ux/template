# frozen_string_literal: true

require "test_helper"

module NotificationRules
  class InventoryAttentionTest < ActiveSupport::TestCase
    def product(key:, availability_status:, **attrs)
      CrmProduct.create!(
        key: key, label: key, status: "confirmed", include_in_analysis: true,
        sql_pattern: "product_name LIKE '%#{key}%'", availability_status: availability_status, **attrs
      )
    end

    def order(product_key:, order_date:, checkout_amount:)
      ShoplineOrder.create!(product_name: product_key, order_date: order_date, checkout_amount: checkout_amount)
    end

    test "out_of_stock product with recent sales is a critical stock conflict" do
      product(key: "metabolism", availability_status: "out_of_stock")
      order(product_key: "metabolism", order_date: 2.days.ago, checkout_amount: 1000)

      result = InventoryAttention.call.find { |r| r[:metadata][:product_key] == "metabolism" }
      assert result.present?
      assert_equal "critical", result[:severity]
      assert_equal 1000, result[:metadata][:recent_checkout_amount]
    end

    test "out_of_stock product with zero recent sales does not conflict" do
      product(key: "metabolism", availability_status: "out_of_stock")

      assert_empty InventoryAttention.call.select { |r| r[:notification_key] == "inventory_stock_conflict" }
    end

    test "preorder product with recent sales is also a critical stock conflict" do
      product(key: "metabolism", availability_status: "preorder")
      order(product_key: "metabolism", order_date: 1.day.ago, checkout_amount: 500)

      result = InventoryAttention.call.find do |r|
        r[:notification_key] == "inventory_stock_conflict" && r[:metadata][:product_key] == "metabolism"
      end
      assert result.present?
    end

    test "discontinued product is excluded from every check, even with a conflicting signal" do
      product(key: "metabolism", availability_status: "discontinued")
      order(product_key: "metabolism", order_date: 1.day.ago, checkout_amount: 1000)

      assert_empty InventoryAttention.call.select { |r| r[:metadata] && r[:metadata][:product_key] == "metabolism" }
    end

    test "out_of_stock product with an overdue expected_restock_date warns" do
      p = product(key: "metabolism", availability_status: "out_of_stock", expected_restock_date: 5.days.ago.to_date)

      result = InventoryAttention.call.find { |r| r[:notification_key] == "inventory_restock_overdue" }
      assert result.present?
      assert_equal "warning", result[:severity]
      assert_equal 5, result[:metadata][:days_overdue]
      assert_equal p.id.to_s, result[:subject_id]
    end

    test "out_of_stock product with a future expected_restock_date does not warn yet" do
      product(key: "metabolism", availability_status: "out_of_stock", expected_restock_date: 5.days.from_now.to_date)

      assert_empty InventoryAttention.call.select { |r| r[:notification_key] == "inventory_restock_overdue" }
    end

    test "in_stock product restocked 3+ days ago with zero sales since warns" do
      product(key: "metabolism", availability_status: "in_stock", actual_restock_date: 4.days.ago.to_date)

      result = InventoryAttention.call.find { |r| r[:notification_key] == "inventory_zero_sales_after_restock" }
      assert result.present?
      assert_equal "warning", result[:severity]
    end

    test "in_stock product restocked 3+ days ago with sales since does not warn" do
      product(key: "metabolism", availability_status: "in_stock", actual_restock_date: 4.days.ago.to_date)
      order(product_key: "metabolism", order_date: 2.days.ago, checkout_amount: 100)

      assert_empty InventoryAttention.call.select { |r| r[:notification_key] == "inventory_zero_sales_after_restock" }
    end

    test "unknown-status products produce a single weekly aggregate card, never a per-product one" do
      product(key: "metabolism", availability_status: "unknown")
      product(key: "collagen", availability_status: "unknown")

      results = InventoryAttention.call.select { |r| r[:notification_key] == "inventory_unknown_weekly" }
      assert_equal 1, results.size
      assert_equal 2, results.first[:metadata][:count]
    end

    test "the unknown weekly card's deduplication_key cycles by week, not staying open forever" do
      product(key: "metabolism", availability_status: "unknown")
      key_this_week = InventoryAttention.call.find { |r| r[:notification_key] == "inventory_unknown_weekly" }[:deduplication_key]

      travel 8.days do
        key_next_week = InventoryAttention.call.find { |r| r[:notification_key] == "inventory_unknown_weekly" }[:deduplication_key]
        assert_not_equal key_this_week, key_next_week
      end
    end

    test "no confirmed products produces no cards" do
      assert_empty InventoryAttention.call
    end
  end
end

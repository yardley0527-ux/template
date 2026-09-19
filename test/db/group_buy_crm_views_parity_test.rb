# frozen_string_literal: true

require_relative "group_buy_crm_view_test_helper"

# The views must not drift from the rules the rest of smartadmin already uses:
#   * which order lines count           -> ShoplineOrder.valid_paid.dedup_content_drift
#   * which product an order line is    -> ProductNameResolver.orders_for (primary product or bundle component)
# If one of those changes, these tests fail and the view SQL has to be revisited on purpose.
class GroupBuyCrmViewsParityTest < ActiveSupport::TestCase
  include GroupBuyCrmViewTestHelper

  setup do
    @customer = build_customer(shopline_id: "GBQ-1", email: "gb.parity@example.com")
    @run1 = build_import_run("p1")
    @run2 = build_import_run("p2")
    @p = build_product("gb_pp", "商品PP")
    @q = build_product("gb_pq", "商品PQ")
    @r = build_product("gb_pr", "商品PR")
    build_mapping("GBP-SINGLE-P", @p)
    build_mapping("GBP-SINGLE-R", @r)
    build_mapping("GBP-BUNDLE",   @p, components: [@p, @q])

    # a deliberately messy set of order lines
    build_order(order_number: "GBP-1", product_name: "GBP-SINGLE-P", customer: @customer, run: @run1)
    build_order(order_number: "GBP-1", product_name: "GBP-SINGLE-P", customer: @customer, run: @run2)                         # re-import
    build_order(order_number: "GBP-2", product_name: "GBP-BUNDLE",   customer: @customer, run: @run1)
    build_order(order_number: "GBP-2", product_name: "GBP-BUNDLE送1", customer: @customer, run: @run2)                       # content drift
    build_order(order_number: "GBP-3", product_name: "GBP-SINGLE-R", customer: @customer, payment_status: "未付款")           # unpaid
    build_order(order_number: "GBP-4", product_name: "GBP-SINGLE-R", customer: @customer)
    build_order(order_number: "GBP-5", product_name: "GBP-BUNDLE",   customer: @customer, quantity: 1, checkout_amount: 3000)
    build_order(order_number: "GBP-5", product_name: "GBP-BUNDLE",   customer: @customer, quantity: 2, checkout_amount: 6000) # repeated line
    build_order(order_number: "GBP-6", product_name: "GBP-UNKNOWN",   customer: @customer)
    build_order(order_number: "GBP-7", product_name: "GBP-SINGLE-P", customer: @customer, checkout_amount: nil)               # NULL amount
    # Existing scope quirk, mirrored on purpose: with NO import run, two different products sharing (order, quantity, amount)
    # are dropped together because NULL = NULL is not true. Real imports always carry an import_run_id.
    build_order(order_number: "GBP-8", product_name: "GBP-SINGLE-P", customer: @customer)
    build_order(order_number: "GBP-8", product_name: "GBP-SINGLE-R", customer: @customer)
    # ...whereas the same two lines from one import are both kept
    build_order(order_number: "GBP-9", product_name: "GBP-SINGLE-P", customer: @customer, run: @run1)
    build_order(order_number: "GBP-9", product_name: "GBP-SINGLE-R", customer: @customer, run: @run1)
  end

  test "the counted (order, product) pairs are exactly those of ShoplineOrder.valid_paid.dedup_content_drift" do
    baseline = ShoplineOrder.valid_paid.dedup_content_drift.pluck(:order_number, :product_name).to_set
    in_view  = OrderLine.pluck(:order_number, :raw_product_name).to_set

    assert_equal baseline, in_view
    assert_operator baseline.size, :>, 3, "the fixture should exercise the scopes"
    assert_not_includes in_view.map(&:first), "GBP-8", "lines without an import run in a differing-name group are dropped, like the baseline"
    assert_includes in_view.map(&:first), "GBP-9"
  end

  test "which orders belong to each product matches ProductNameResolver.orders_for (primary product or bundle component)" do
    %w[gb_pp gb_pq gb_pr].each do |key|
      resolver_orders = ProductNameResolver.orders_for(key).valid_paid.dedup_content_drift
                                           .distinct.pluck("shopline_orders.order_number").to_set
      view_orders = OrderLine.where(mapping_status: "mapped")
                             .select { |l| l.product_key == key || Array(l.bundle_component_keys).include?(key) }
                             .map(&:order_number).to_set

      assert_equal resolver_orders, view_orders, "orders for #{key}"
    end
  end

  test "the per-member purchase count matches counting the resolver's distinct orders" do
    summaries = summaries_for(@customer)
    %w[gb_pp gb_pq gb_pr].each do |key|
      expected = ProductNameResolver.orders_for(key).valid_paid.dedup_content_drift
                                    .where(shopline_customer_id: @customer.id)
                                    .distinct.count("shopline_orders.order_number")
      assert_equal expected, summaries[key]&.order_count.to_i, "purchase count for #{key}"
    end
  end
end

# frozen_string_literal: true

require_relative "group_buy_crm_view_test_helper"

class GroupBuyCrmMemberProductSummariesTest < ActiveSupport::TestCase
  include GroupBuyCrmViewTestHelper

  setup do
    @customer = build_customer(shopline_id: "GBS1", email: "gb.sum@example.com")
    @run1 = build_import_run("s1")
    @run2 = build_import_run("s2")
    @p = build_product("gb_p", "商品P")
    @q = build_product("gb_q", "商品Q")
  end

  test "the purchase count is the number of distinct orders, however many paths hit the same product in one order" do
    build_mapping("GB-BUNDLE", @p, components: [@p, @q]) # primary product is also its own component
    build_mapping("GB-SINGLE-P", @p)
    build_order(order_number: "GB-O1", product_name: "GB-BUNDLE", customer: @customer)
    build_order(order_number: "GB-O2", product_name: "GB-BUNDLE", customer: @customer)
    build_order(order_number: "GB-O3", product_name: "GB-SINGLE-P", customer: @customer)
    # one order reaching P three ways: bundle primary + bundle component + another single line
    # (same import run, like a real import: two different products with equal quantity/amount in one order are both kept)
    build_order(order_number: "GB-O4", product_name: "GB-BUNDLE",   customer: @customer, run: @run1)
    build_order(order_number: "GB-O4", product_name: "GB-SINGLE-P", customer: @customer, run: @run1)

    rows = summaries_for(@customer)
    assert_equal 4, rows["gb_p"].order_count, "P is in orders O1..O4 - each counted once (COUNT(*) would say 7)"
    assert_equal 3, rows["gb_q"].order_count, "Q only reaches the customer through the bundle components (O1, O2, O4)"
    assert_equal %w[gb_p gb_q], rows.keys.sort
    assert rows.values.all? { |r| r.mapping_status == "mapped" }
  end

  test "first and last purchase dates come from the counted orders" do
    build_mapping("GB-SINGLE-P", @p)
    build_order(order_number: "GB-D1", product_name: "GB-SINGLE-P", customer: @customer, order_date: Time.utc(2026, 1, 10, 3))
    build_order(order_number: "GB-D2", product_name: "GB-SINGLE-P", customer: @customer, order_date: Time.utc(2026, 5, 20, 3))
    build_order(order_number: "GB-D3", product_name: "GB-SINGLE-P", customer: @customer, order_date: Time.utc(2026, 9, 1, 3), payment_status: "未付款")

    row = summaries_for(@customer)["gb_p"]
    assert_equal Time.utc(2026, 1, 10, 3), row.first_order_date.utc
    assert_equal Time.utc(2026, 5, 20, 3), row.last_order_date.utc
    assert_equal 2, row.order_count
  end

  test "duplicate imports of the same order line do not inflate the purchase count" do
    build_mapping("GB-SINGLE-P", @p)
    build_order(order_number: "GB-R1", product_name: "GB-SINGLE-P", customer: @customer, run: @run1)
    build_order(order_number: "GB-R1", product_name: "GB-SINGLE-P", customer: @customer, run: @run2)

    assert_equal 1, summaries_for(@customer)["gb_p"].order_count
  end

  test "a mapping conflict is never rolled into either candidate product and shows up as its own conflict entry" do
    build_mapping("GB-CLASH", @p, source: "shopline_order")
    build_mapping("GB-CLASH", @q, source: "livestream_product")
    build_mapping("GB-SINGLE-P", @p)
    build_order(order_number: "GB-K1", product_name: "GB-CLASH",    customer: @customer)
    build_order(order_number: "GB-K2", product_name: "GB-SINGLE-P", customer: @customer)

    rows = summaries_for(@customer)
    assert_equal 1, rows["gb_p"].order_count, "only the unambiguous order counts for P"
    assert_nil rows["gb_q"], "Q must not appear: the conflict was not applied to it either"

    clash = rows["raw:GB-CLASH"]
    assert_not_nil clash
    assert_equal "conflict", clash.mapping_status
    assert_equal "GB-CLASH", clash.product_label
    assert_equal 1, clash.order_count
  end

  test "unmapped names stay separate from every product and are labelled with their raw name" do
    build_order(order_number: "GB-U1", product_name: "沒有對應的商品",  customer: @customer)
    build_order(order_number: "GB-U2", product_name: "另一個沒對應",    customer: @customer)
    build_order(order_number: "GB-U3", product_name: "沒有對應的商品",  customer: @customer)

    rows = summaries_for(@customer)
    assert_equal ["raw:另一個沒對應", "raw:沒有對應的商品"].sort, rows.keys.sort
    assert_equal 2, rows["raw:沒有對應的商品"].order_count
    assert_equal "沒有對應的商品", rows["raw:沒有對應的商品"].product_label
    assert rows.values.all? { |r| r.mapping_status == "unmapped" }
  end

  test "only lines attributed to the member are summarised, and members without lines have no rows" do
    build_mapping("GB-SINGLE-P", @p)
    other = build_customer(shopline_id: "GBS2", email: "gb.other2@example.com")
    build_order(order_number: "GB-M1", product_name: "GB-SINGLE-P", customer: @customer)
    build_order(order_number: "GB-M2", product_name: "GB-SINGLE-P", customer_id: nil, email: "nobody@example.com") # unattributed

    assert_equal 1, summaries_for(@customer)["gb_p"].order_count
    assert_empty summaries_for(other)
    assert_equal 1, ProductSummary.count
  end
end

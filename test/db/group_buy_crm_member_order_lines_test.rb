# frozen_string_literal: true

require_relative "group_buy_crm_view_test_helper"

class GroupBuyCrmMemberOrderLinesTest < ActiveSupport::TestCase
  include GroupBuyCrmViewTestHelper

  setup do
    @customer = build_customer(shopline_id: "GBC1", email: "gb.main@example.com")
    @run1 = build_import_run("1")
    @run2 = build_import_run("2")
    @run3 = build_import_run("3")
  end

  # ── baseline: valid_paid + dedup_content_drift ────────────────────────────────

  test "unpaid, blank-email, undated and NULL quantity/amount lines never appear (same as valid_paid.dedup_content_drift)" do
    build_order(order_number: "GB-X1", product_name: "薑黃3", customer: @customer, payment_status: "未付款")
    build_order(order_number: "GB-X2", product_name: "薑黃3", customer: @customer, email: "")
    build_order(order_number: "GB-X3", product_name: "薑黃3", customer: @customer, order_date: nil)
    build_order(order_number: "GB-X4", product_name: "薑黃3", customer: @customer, checkout_amount: nil) # existing scope drops these silently
    build_order(order_number: "GB-X5", product_name: "薑黃3", customer: @customer, quantity: nil)
    build_order(order_number: "GB-OK", product_name: "薑黃3", customer: @customer)

    assert_equal ["GB-OK"], OrderLine.pluck(:order_number)
  end

  test "content drift: the same line re-exported under a changed name keeps only the newest import's name" do
    build_order(order_number: "GB-D1", product_name: "薑黃3",   customer: @customer, run: @run1)
    build_order(order_number: "GB-D1", product_name: "薑黃3送1", customer: @customer, run: @run2)

    assert_equal ["薑黃3送1"], lines_for("GB-D1").map(&:raw_product_name)
  end

  # ── canonical lines ───────────────────────────────────────────────────────────

  test "a line re-imported unchanged in a later import is one canonical line, not two" do
    build_order(order_number: "GB-C1", product_name: "薑黃3", customer: @customer, run: @run1)
    build_order(order_number: "GB-C1", product_name: "薑黃3", customer: @customer, run: @run2)

    line = only_line("GB-C1")
    assert_equal 1, line.line_quantity
    assert_equal 1, line.source_line_count
  end

  test "a re-import with a drifted amount does not double the quantity" do
    build_order(order_number: "GB-C2", product_name: "薑黃3", customer: @customer, run: @run1, checkout_amount: 900)
    build_order(order_number: "GB-C2", product_name: "薑黃3", customer: @customer, run: @run2, checkout_amount: 850)

    assert_equal 1, only_line("GB-C2").line_quantity
  end

  test "genuinely repeated items inside one import are kept and their quantities add up" do
    build_order(order_number: "GB-C3", product_name: "薑黃3", customer: @customer, run: @run1, quantity: 1, checkout_amount: 900)
    build_order(order_number: "GB-C3", product_name: "薑黃3", customer: @customer, run: @run1, quantity: 2, checkout_amount: 1800)

    line = only_line("GB-C3")
    assert_equal 3, line.line_quantity
    assert_equal 2, line.source_line_count
  end

  test "an item that only exists in an older import is still kept (latest-import-wins is per order line, not per order)" do
    build_order(order_number: "GB-C4", product_name: "薑黃3", customer: @customer, run: @run1)
    build_order(order_number: "GB-C4", product_name: "全能6", customer: @customer, run: @run1, checkout_amount: 3000)
    build_order(order_number: "GB-C4", product_name: "薑黃3", customer: @customer, run: @run2)

    assert_equal ["全能6", "薑黃3"], lines_for("GB-C4").map(&:raw_product_name).sort
  end

  test "canonical lines never repeat: the recent-lines list can not show a duplicate" do
    3.times { |i| build_order(order_number: "GB-C5", product_name: "薑黃3", customer: @customer, run: [@run1, @run2, @run3][i]) }
    build_order(order_number: "GB-C5", product_name: "全能6", customer: @customer, run: @run3, checkout_amount: 3000)

    recent = OrderLine.where(shopline_customer_id: @customer.id).order(order_date: :desc, order_line_key: :asc).limit(10).to_a
    assert_equal recent.map(&:order_line_key).uniq, recent.map(&:order_line_key)
    assert_equal 2, recent.size
  end

  # ── order_line_key ────────────────────────────────────────────────────────────

  test "order_line_key is unambiguous: the classic separator collision produces two different keys" do
    # naive order_number || '|' || product_name gives "X|1|Y" for both
    build_order(order_number: "GB-X|1", product_name: "Y",   customer: @customer)
    build_order(order_number: "GB-X",   product_name: "1|Y", customer: @customer)

    keys = OrderLine.where(order_number: ["GB-X|1", "GB-X"]).pluck(:order_line_key)
    assert_equal 2, keys.size
    assert_equal 2, keys.uniq.size
  end

  test "order_line_key is unique and reversible for names with |, newlines, quotes, backslashes, emoji and full-width bars" do
    names = ["A|B", "A\nB", %(He said "hi"), "back\\slash", "薑黃3 💊", "全形｜直線", "tab\tname", "  leading space", "", "'single'"]
    names.each_with_index { |n, i| build_order(order_number: "GB-K#{i}", product_name: n, customer: @customer) }
    build_order(order_number: "GB-K-dup", product_name: "A|B", customer: @customer) # same name, different order

    rows = OrderLine.all.to_a
    assert_equal names.size + 1, rows.size
    assert_equal rows.size, rows.map(&:order_line_key).uniq.size
    rows.each do |row|
      assert_equal [row.order_number, row.raw_product_name], JSON.parse(row.order_line_key),
                   "key must decode back to [order_number, product_name]"
    end
  end

  test "order_line_key is stable: same (order_number, product_name) always yields the same key, whatever the import" do
    build_order(order_number: "GB-S1", product_name: "薑黃3", customer: @customer, run: @run1, quantity: 1)
    key_before = only_line("GB-S1").order_line_key

    build_order(order_number: "GB-S1", product_name: "薑黃3", customer: @customer, run: @run3, quantity: 5, checkout_amount: 123)
    assert_equal key_before, only_line("GB-S1").order_line_key
    assert_equal JSON.generate(["GB-S1", "薑黃3"]).delete(" "), key_before.delete(" ")
  end

  test "OrderLine can be looked up by its primary key" do
    build_order(order_number: "GB-P1", product_name: "薑黃3", customer: @customer)
    key = only_line("GB-P1").order_line_key
    assert_equal "GB-P1", OrderLine.find(key).order_number
  end

  # ── product mapping: 0 / 1 / many confirmed_alias ─────────────────────────────

  def prepare_mappings
    @pa = build_product("gb_pa", "商品A")
    @pb = build_product("gb_pb", "商品B")
    build_mapping("GB-ONE", @pa)
    build_mapping("GB-TWO", @pa, source: "shopline_order")
    build_mapping("GB-TWO", @pb, source: "livestream_product") # different product under another source
    build_mapping("GB-SAME", @pa, source: "shopline_order")
    build_mapping("GB-SAME", @pa, source: "livestream_product") # many candidates, same product
    build_mapping("GB-NOPRODUCT", nil)                           # confirmed but no product
    build_mapping("GB-IGNORED", @pa, status: "ignored")
    build_mapping("GB-PENDING", @pa, status: "pending")
    %w[GB-NONE GB-ONE GB-TWO GB-SAME GB-NOPRODUCT GB-IGNORED GB-PENDING].each_with_index do |name, i|
      build_order(order_number: "GB-M#{i}", product_name: name, customer: @customer)
    end
  end

  def line_for_product(name) = OrderLine.find_by!(raw_product_name: name)

  test "no confirmed_alias: unmapped, zero candidates, no product" do
    prepare_mappings
    line = line_for_product("GB-NONE")
    assert_equal "unmapped", line.mapping_status
    assert_equal 0, line.mapping_candidate_count
    assert_nil line.product_key
    assert_nil line.product_label
  end

  test "exactly one confirmed_alias: mapped and applied" do
    prepare_mappings
    line = line_for_product("GB-ONE")
    assert_equal "mapped", line.mapping_status
    assert_equal 1, line.mapping_candidate_count
    assert_equal "gb_pa", line.product_key
    assert_equal "商品A", line.product_label
  end

  test "several confirmed_alias with different products: conflict, nothing applied, raw name kept" do
    prepare_mappings
    line = line_for_product("GB-TWO")
    assert_equal "conflict", line.mapping_status
    assert_equal 2, line.mapping_candidate_count
    assert_nil line.product_key,   "must not silently pick one of the candidates"
    assert_nil line.product_label
    assert_nil line.bundle_component_keys
    assert_equal "GB-TWO", line.raw_product_name
  end

  test "several confirmed_alias even when they agree on the same product: still flagged as conflict (fail-safe, never picks one)" do
    prepare_mappings
    line = line_for_product("GB-SAME")
    assert_equal "conflict", line.mapping_status
    assert_equal 2, line.mapping_candidate_count
    assert_nil line.product_key
  end

  test "conflict never multiplies rows" do
    prepare_mappings
    assert_equal 7, OrderLine.count
    assert_equal 1, OrderLine.where(raw_product_name: "GB-TWO").count
  end

  test "confirmed_alias without a product, ignored and pending mappings are all unmapped" do
    prepare_mappings
    %w[GB-NOPRODUCT GB-IGNORED GB-PENDING].each do |name|
      line = line_for_product(name)
      assert_equal "unmapped", line.mapping_status, name
      assert_nil line.product_key, name
    end
    assert_equal 1, line_for_product("GB-NOPRODUCT").mapping_candidate_count
    assert_equal 0, line_for_product("GB-IGNORED").mapping_candidate_count
  end

  test "bundle components come only from a mapped line and are sorted keys (the primary product may be one of them)" do
    pa = build_product("gb_pa"); pb = build_product("gb_pb")
    build_mapping("GB-BUNDLE", pa, components: [pb, pa])
    build_order(order_number: "GB-B1", product_name: "GB-BUNDLE", customer: @customer)

    line = only_line("GB-B1")
    assert_equal "mapped", line.mapping_status
    assert_equal %w[gb_pa gb_pb], line.bundle_component_keys
  end

  # ── member attribution ───────────────────────────────────────────────────────

  test "an order with a valid shopline_customer_id belongs to that customer" do
    build_order(order_number: "GB-A1", product_name: "薑黃3", customer: @customer)
    line = only_line("GB-A1")
    assert_equal @customer.id, line.shopline_customer_id
    assert_equal "order_customer_id", line.customer_link_source
    assert line.email_consistent
  end

  test "a valid id whose order email differs from the member's email still belongs to the member but is flagged" do
    build_order(order_number: "GB-A2", product_name: "薑黃3", customer: @customer, email: "someone.else@example.com")
    line = only_line("GB-A2")
    assert_equal @customer.id, line.shopline_customer_id
    assert_equal "order_customer_id", line.customer_link_source
    assert_equal false, line.email_consistent
  end

  test "email consistency ignores case and surrounding whitespace" do
    build_order(order_number: "GB-A3", product_name: "薑黃3", customer: @customer, email: "  GB.MAIN@Example.COM　")
    assert only_line("GB-A3").email_consistent
  end

  test "no id and an email matching nobody: not attributed" do
    build_order(order_number: "GB-A4", product_name: "薑黃3", customer_id: nil, email: "nobody@example.com")
    line = only_line("GB-A4")
    assert_nil line.shopline_customer_id
    assert_nil line.customer_link_source
  end

  test "email normalization: case, half-width and full-width surrounding spaces and zero-width characters all match" do
    member = build_customer(shopline_id: "GBN1", email: "GB.Upper​@Example.COM　") # messy on the member side too
    variants = ["gb.upper@example.com", "  gb.upper@example.com  ", "　GB.UPPER@EXAMPLE.COM　",
                "gb.upper​@example.com", "gb‌.upper@example.com﻿"]
    variants.each_with_index { |e, i| build_order(order_number: "GB-N#{i}", product_name: "薑黃3", customer_id: nil, email: e) }

    variants.each_index do |i|
      line = only_line("GB-N#{i}")
      assert_equal member.id, line.shopline_customer_id, "variant #{variants[i].inspect}"
      assert_equal "unique_email", line.customer_link_source
    end
  end

  test "email normalization does not touch Gmail dots or plus tags, or the domain" do
    dotted = build_customer(shopline_id: "GBG1", email: "a.b+tag@gmail.com")
    plain  = build_customer(shopline_id: "GBG2", email: "ab@gmail.com")
    {
      "GB-G1" => ["ab@gmail.com", plain.id], "GB-G2" => ["AB@GMAIL.COM", plain.id],
      "GB-G3" => ["a.b+tag@gmail.com", dotted.id], "GB-G4" => ["a.b+TAG@gmail.com", dotted.id],
      "GB-G5" => ["a.b@gmail.com", nil], "GB-G6" => ["ab+tag@gmail.com", nil], "GB-G7" => ["ab@googlemail.com", nil]
    }.each do |order_number, (email, expected)|
      build_order(order_number: order_number, product_name: "薑黃3", customer_id: nil, email: email)
      actual = only_line(order_number).shopline_customer_id
      expected.nil? ? assert_nil(actual, "#{email} on #{order_number}") : assert_equal(expected, actual, "#{email} on #{order_number}")
    end
  end

  test "an email that normalizes to several members attributes nobody and never multiplies the order rows" do
    build_customer(shopline_id: "GBM1", email: "dup@example.com")
    build_customer(shopline_id: "GBM2", email: "DUP@example.com")
    build_customer(shopline_id: "GBM3", email: "dup@example.com　")
    2.times { |i| build_order(order_number: "GB-MM#{i}", product_name: "薑黃3", customer_id: nil, email: "dup@example.com") }

    2.times do |i|
      line = only_line("GB-MM#{i}") # exactly one row each
      assert_nil line.shopline_customer_id
      assert_nil line.customer_link_source
    end
    assert_equal 2, OrderLine.count
  end

  test "a valid id wins over an ambiguous email" do
    build_customer(shopline_id: "GBM4", email: "dup2@example.com")
    build_customer(shopline_id: "GBM5", email: "DUP2@example.com")
    build_order(order_number: "GB-MM9", product_name: "薑黃3", customer: @customer, email: "dup2@example.com")
    assert_equal @customer.id, only_line("GB-MM9").shopline_customer_id
  end

  test "two different customer ids on the same order line is a conflict: attributed to nobody" do
    other = build_customer(shopline_id: "GBC2", email: "gb.other@example.com")
    build_order(order_number: "GB-T3", product_name: "薑黃3", customer: @customer, run: @run1, quantity: 1, checkout_amount: 900)
    build_order(order_number: "GB-T3", product_name: "薑黃3", customer: other,     run: @run1, quantity: 2, checkout_amount: 1800)

    line = only_line("GB-T3")
    assert_nil line.shopline_customer_id
    assert_nil line.customer_link_source
  end

  test "a dangling shopline_customer_id is not attributed and is not silently repaired from the email" do
    drop_orders_customer_fk!
    build_order(order_number: "GB-T2", product_name: "薑黃3", customer_id: 987_654_321, email: @customer.email)

    line = only_line("GB-T2")
    assert_nil line.shopline_customer_id
    assert_nil line.customer_link_source
  end

  test "attribution never depends on which import an order line came from" do
    build_order(order_number: "GB-I1", product_name: "薑黃3", customer_id: nil, email: "gb.main@example.com", run: @run1)
    build_order(order_number: "GB-I1", product_name: "薑黃3", customer: @customer,                           run: @run2)
    assert_equal @customer.id, only_line("GB-I1").shopline_customer_id
  end
end

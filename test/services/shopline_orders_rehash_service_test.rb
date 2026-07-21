# frozen_string_literal: true

require "test_helper"

class ShoplineOrdersRehashServiceTest < ActiveSupport::TestCase
  def old_hash(order_number:, product_name:, quantity:, checkout_amount:, total_amount:)
    Digest::SHA256.hexdigest(
      JSON.generate(order_number: order_number.to_s.strip, product_name: product_name.to_s.strip,
                    quantity: quantity.to_i, checkout_amount: ShoplineOrder.format_decimal(checkout_amount),
                    total_amount: ShoplineOrder.format_decimal(total_amount))
    )
  end

  def create_with_old_hash(order_number:, product_name:, checkout_amount:, total_amount:, quantity: 1)
    ShoplineOrder.create!(
      order_number: order_number, product_name: product_name, quantity: quantity,
      checkout_amount: checkout_amount, total_amount: total_amount,
      payment_status: "已付款", order_date: 5.days.ago,
      source_row_hash: old_hash(order_number: order_number, product_name: product_name, quantity: quantity,
                                checkout_amount: checkout_amount, total_amount: total_amount)
    )
  end

  test "dry-run reports rows to rehash without writing" do
    row = create_with_old_hash(order_number: "#R1", product_name: "薑黃6",
                               checkout_amount: 10050, total_amount: 15830)
    original_hash = row.source_row_hash

    result = ShoplineOrdersRehashService.call(apply: false)

    assert_equal 1, result[:rows_to_rehash]
    assert_equal false, result[:applied]
    assert_equal original_hash, row.reload.source_row_hash
  end

  test "apply writes the new hash and it matches ShoplineOrder.content_hash" do
    row = create_with_old_hash(order_number: "#R2", product_name: "清纖粉2",
                               checkout_amount: 3683, total_amount: 3683)

    ShoplineOrdersRehashService.call(apply: true)

    expected = ShoplineOrder.content_hash(order_number: "#R2", product_name: "清纖粉2",
                                          quantity: 1, checkout_amount: 3683, occurrence: 1)
    assert_equal expected, row.reload.source_row_hash
  end

  test "pattern-A duplicate pair (total_amount present vs NULL) gets distinct occurrence and no collision" do
    kept   = create_with_old_hash(order_number: "#R3", product_name: "薑黃6",
                                  checkout_amount: 10050, total_amount: 15830)
    dupe   = create_with_old_hash(order_number: "#R3", product_name: "薑黃6",
                                  checkout_amount: 10050, total_amount: nil)

    ShoplineOrdersRehashService.call(apply: true)

    kept.reload
    dupe.reload
    assert_not_equal kept.source_row_hash, dupe.source_row_hash
    assert_equal ShoplineOrder.content_hash(order_number: "#R3", product_name: "薑黃6", quantity: 1,
                                            checkout_amount: 10050, occurrence: 1), kept.source_row_hash
    assert_equal ShoplineOrder.content_hash(order_number: "#R3", product_name: "薑黃6", quantity: 1,
                                            checkout_amount: 10050, occurrence: 2), dupe.source_row_hash
  end

  test "already-current hashes are left untouched (idempotent)" do
    row = ShoplineOrder.create!(
      order_number: "#R4", product_name: "私密粉1", quantity: 1, checkout_amount: 1980,
      payment_status: "已付款", order_date: 1.day.ago,
      source_row_hash: ShoplineOrder.content_hash(order_number: "#R4", product_name: "私密粉1",
                                                   quantity: 1, checkout_amount: 1980, occurrence: 1)
    )
    current_hash = row.source_row_hash

    result = ShoplineOrdersRehashService.call(apply: true)

    assert_equal 0, result[:rows_to_rehash]
    assert_equal current_hash, row.reload.source_row_hash
  end

  test "running apply twice is a no-op the second time" do
    create_with_old_hash(order_number: "#R5", product_name: "全能3",
                         checkout_amount: 3200, total_amount: 3200)

    first  = ShoplineOrdersRehashService.call(apply: true)
    second = ShoplineOrdersRehashService.call(apply: true)

    assert_equal 1, first[:rows_to_rehash]
    assert_equal 0, second[:rows_to_rehash]
  end

  test "does not touch unrelated columns" do
    row = create_with_old_hash(order_number: "#R6", product_name: "膠原蛋白1",
                               checkout_amount: 2980, total_amount: 8000)
    original_updated_at = row.updated_at

    ShoplineOrdersRehashService.call(apply: true)
    row.reload

    assert_equal BigDecimal("8000"), row.total_amount
    assert_equal BigDecimal("2980"), row.checkout_amount
    # update_all bypasses callbacks/timestamps entirely — confirms this is a
    # narrow column write, not a full record save.
    assert_in_delta original_updated_at.to_f, row.updated_at.to_f, 0.01
  end
end

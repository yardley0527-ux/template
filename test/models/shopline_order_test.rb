# frozen_string_literal: true

require "test_helper"

class ShoplineOrderTest < ActiveSupport::TestCase
  test "dedup_content_drift keeps only the most recently imported row when product_name drifted across import runs" do
    old_run = ImportRun.create!(kind: "paid_orders_workbook", file_name: "old.csv", file_checksum: SecureRandom.hex(8))
    new_run = ImportRun.create!(kind: "paid_orders_workbook", file_name: "new.csv", file_checksum: SecureRandom.hex(8))

    stale = ShoplineOrder.create!(order_number: "#SO1", product_name: "薑黃6", payment_status: "已付款",
                                  quantity: 1, checkout_amount: 10500, order_date: Time.zone.now,
                                  source_year: 2026, source_month: 1, import_run_id: old_run.id,
                                  source_row_hash: SecureRandom.hex(8))
    fresh = ShoplineOrder.create!(order_number: "#SO1", product_name: "薑黃6送1", payment_status: "已付款",
                                  quantity: 1, checkout_amount: 10500, order_date: Time.zone.now,
                                  source_year: 2026, source_month: 1, import_run_id: new_run.id,
                                  source_row_hash: SecureRandom.hex(8))

    result = ShoplineOrder.where(order_number: "#SO1").dedup_content_drift

    assert_equal [fresh.id], result.pluck(:id)
    assert ShoplineOrder.exists?(stale.id), "the orphan row itself must not be deleted, only excluded from this scope"
  end

  test "dedup_content_drift keeps both rows when different product_name shares the same import_run (genuinely distinct line items, not drift)" do
    run = ImportRun.create!(kind: "paid_orders_workbook", file_name: "single.csv", file_checksum: SecureRandom.hex(8))

    gift_a = ShoplineOrder.create!(order_number: "#SO2", product_name: "贈品A", payment_status: "已付款",
                                   quantity: 1, checkout_amount: 0, order_date: Time.zone.now,
                                   source_year: 2026, source_month: 1, import_run_id: run.id,
                                   source_row_hash: SecureRandom.hex(8))
    gift_b = ShoplineOrder.create!(order_number: "#SO2", product_name: "贈品B", payment_status: "已付款",
                                   quantity: 1, checkout_amount: 0, order_date: Time.zone.now,
                                   source_year: 2026, source_month: 1, import_run_id: run.id,
                                   source_row_hash: SecureRandom.hex(8))

    result = ShoplineOrder.where(order_number: "#SO2").dedup_content_drift

    assert_equal [gift_a.id, gift_b.id].sort, result.pluck(:id).sort
  end

  test "dedup_content_drift keeps a genuine occurrence-based repeat of the same line untouched" do
    run = ImportRun.create!(kind: "paid_orders_workbook", file_name: "repeat.csv", file_checksum: SecureRandom.hex(8))

    line1 = ShoplineOrder.create!(order_number: "#SO3", product_name: "清纖粉2", payment_status: "已付款",
                                  quantity: 1, checkout_amount: 1980, order_date: Time.zone.now,
                                  source_year: 2026, source_month: 1, import_run_id: run.id,
                                  source_row_hash: SecureRandom.hex(8))
    line2 = ShoplineOrder.create!(order_number: "#SO3", product_name: "清纖粉2", payment_status: "已付款",
                                  quantity: 1, checkout_amount: 1980, order_date: Time.zone.now,
                                  source_year: 2026, source_month: 1, import_run_id: run.id,
                                  source_row_hash: SecureRandom.hex(8))

    result = ShoplineOrder.where(order_number: "#SO3").dedup_content_drift

    assert_equal [line1.id, line2.id].sort, result.pluck(:id).sort
  end
end

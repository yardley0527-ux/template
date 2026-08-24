# frozen_string_literal: true

require "test_helper"

module Importing
  class CanceledOrderCandidatesTest < ActiveSupport::TestCase
    test "returns none when no import run exists for the period" do
      result = CanceledOrderCandidates.call(year: 1999, month: 1)
      assert_empty result
    end

    test "flags a paid order not touched by the latest import run for its period" do
      old_run = ImportRun.create!(kind: "paid_orders_workbook", file_name: "old.csv", file_checksum: "a")
      new_run = ImportRun.create!(kind: "paid_orders_workbook", file_name: "new.csv", file_checksum: "b")

      stale = ShoplineOrder.create!(order_number: "#20260115120000030", product_name: "薑黃1",
                                    payment_status: "已付款", quantity: 1, checkout_amount: 1780,
                                    order_date: Time.zone.local(2026, 1, 15), source_year: 2026, source_month: 1,
                                    import_run_id: old_run.id, source_row_hash: "stale-hash-1")
      ShoplineOrder.create!(order_number: "#20260115120000031", product_name: "薑黃1",
                            payment_status: "已付款", quantity: 1, checkout_amount: 1780,
                            order_date: Time.zone.local(2026, 1, 15), source_year: 2026, source_month: 1,
                            import_run_id: new_run.id, source_row_hash: "fresh-hash-1")

      result = CanceledOrderCandidates.call(year: 2026, month: 1)

      assert_equal [stale.id], result.pluck(:id)
    end

    test "does not flag an order whose product_name text drifted between exports (same order_number touched by the latest run)" do
      old_run = ImportRun.create!(kind: "paid_orders_workbook", file_name: "old.csv", file_checksum: "e")
      new_run = ImportRun.create!(kind: "paid_orders_workbook", file_name: "new.csv", file_checksum: "f")

      # Same real order, but Shopline's later export appended a gift suffix
      # to 商品名稱 ("薑黃6" -> "薑黃6送1"), so content_hash misses and the
      # importer lands it as a second row instead of updating the first —
      # leaving an orphan row that must not be treated as canceled.
      orphan = ShoplineOrder.create!(order_number: "#20260115120000040", product_name: "薑黃6",
                                     payment_status: "已付款", quantity: 1, checkout_amount: 10500,
                                     order_date: Time.zone.local(2026, 1, 15), source_year: 2026, source_month: 1,
                                     import_run_id: old_run.id, source_row_hash: "drift-hash-old")
      ShoplineOrder.create!(order_number: "#20260115120000040", product_name: "薑黃6送1",
                            payment_status: "已付款", quantity: 1, checkout_amount: 10500,
                            order_date: Time.zone.local(2026, 1, 15), source_year: 2026, source_month: 1,
                            import_run_id: new_run.id, source_row_hash: "drift-hash-new")

      result = CanceledOrderCandidates.call(year: 2026, month: 1)

      assert_empty result
      assert ShoplineOrder.exists?(orphan.id)
    end

    test "does not flag unpaid orders even if untouched by the latest run" do
      old_run = ImportRun.create!(kind: "paid_orders_workbook", file_name: "old.csv", file_checksum: "c")
      new_run = ImportRun.create!(kind: "paid_orders_workbook", file_name: "new.csv", file_checksum: "d")

      ShoplineOrder.create!(order_number: "#20260115120000032", product_name: "薑黃1",
                            payment_status: "未付款", quantity: 1, checkout_amount: 1780,
                            order_date: Time.zone.local(2026, 1, 15), source_year: 2026, source_month: 1,
                            import_run_id: old_run.id, source_row_hash: "stale-hash-2")
      ShoplineOrder.create!(order_number: "#20260115120000033", product_name: "薑黃1",
                            payment_status: "已付款", quantity: 1, checkout_amount: 1780,
                            order_date: Time.zone.local(2026, 1, 15), source_year: 2026, source_month: 1,
                            import_run_id: new_run.id, source_row_hash: "fresh-hash-2")

      result = CanceledOrderCandidates.call(year: 2026, month: 1)

      assert_empty result
    end
  end
end

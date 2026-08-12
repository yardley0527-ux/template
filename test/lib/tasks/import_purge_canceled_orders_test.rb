# frozen_string_literal: true

require "test_helper"
require "rake"

class ImportPurgeCanceledOrdersTest < ActiveSupport::TestCase
  setup do
    unless $rake_tasks_loaded_for_tests
      Rails.application.load_tasks
      $rake_tasks_loaded_for_tests = true
    end
    Rake::Task["import:purge_canceled_orders"].reenable
  end

  test "deletes candidates for the given year/month and refreshes caches" do
    old_run = ImportRun.create!(kind: "paid_orders_workbook", file_name: "old.csv", file_checksum: "e")
    new_run = ImportRun.create!(kind: "paid_orders_workbook", file_name: "new.csv", file_checksum: "f")

    stale = ShoplineOrder.create!(order_number: "#20260115120000040", product_name: "薑黃1",
                                  payment_status: "已付款", quantity: 1, checkout_amount: 1780,
                                  order_date: Time.zone.local(2026, 1, 15), source_year: 2026, source_month: 1,
                                  import_run_id: old_run.id, source_row_hash: "purge-stale-1")
    kept = ShoplineOrder.create!(order_number: "#20260115120000041", product_name: "薑黃1",
                                 payment_status: "已付款", quantity: 1, checkout_amount: 1780,
                                 order_date: Time.zone.local(2026, 1, 15), source_year: 2026, source_month: 1,
                                 import_run_id: new_run.id, source_row_hash: "purge-fresh-1")

    silence_stream_output { Rake::Task["import:purge_canceled_orders"].invoke("2026", "1") }

    assert_not ShoplineOrder.exists?(stale.id)
    assert ShoplineOrder.exists?(kept.id)
  end

  test "does nothing when there are no candidates for the given period" do
    before = ShoplineOrder.count
    silence_stream_output { Rake::Task["import:purge_canceled_orders"].invoke("1999", "1") }
    assert_equal before, ShoplineOrder.count
  end

  private

  def silence_stream_output
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original_stdout
  end
end

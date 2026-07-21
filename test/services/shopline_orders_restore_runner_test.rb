# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/shopline_orders_restore_runner")

class ShoplineOrdersRestoreRunnerTest < ActiveSupport::TestCase
  def apply_dedupe_and_capture_run_id(order_number:)
    a = ShoplineOrder.create!(order_number: order_number, product_name: "薑黃6", quantity: 1,
                              checkout_amount: 10050, total_amount: 15830, payment_status: "已付款",
                              order_date: Time.current, import_run_id: 1, email: "runner@example.com")
    ShoplineOrder.create!(order_number: order_number, product_name: "薑黃6", quantity: 1,
                         checkout_amount: 10050, total_amount: nil, payment_status: "已付款",
                         order_date: a.order_date, import_run_id: 2, email: "runner@example.com")

    ShoplineOrdersDedupeService.call(apply: true)[:dedupe_run_id]
  end

  test "dry_run writes no SyncRun" do
    run_id = apply_dedupe_and_capture_run_id(order_number: "#RRN1")
    capture_io { ShoplineOrdersRestoreRunner.dry_run(dedupe_run_id: run_id) }

    assert_nil SyncRun.latest_for("shopline_orders_restore")
  end

  test "apply records a success SyncRun and stores the dedupe_run_id in meta" do
    run_id = apply_dedupe_and_capture_run_id(order_number: "#RRN2")
    capture_io { ShoplineOrdersRestoreRunner.apply(dedupe_run_id: run_id) }

    run = SyncRun.latest_for("shopline_orders_restore")
    assert_equal "success", run.status
    assert_equal run_id, run.meta["dedupe_run_id"]
    assert_equal 1, run.meta["restored_count"]
  end

  test "apply with an unknown run_id still records success with zero restored" do
    capture_io { ShoplineOrdersRestoreRunner.apply(dedupe_run_id: "bogus") }

    run = SyncRun.latest_for("shopline_orders_restore")
    assert_equal "success", run.status
    assert_equal 0, run.meta["restored_count"]
  end

  test "a crash inside the service leaves a failed SyncRun and re-raises" do
    run_id = apply_dedupe_and_capture_run_id(order_number: "#RRN3")

    original = ShoplineOrdersRestoreService.method(:call)
    ShoplineOrdersRestoreService.define_singleton_method(:call) do |*|
      raise ActiveRecord::StatementInvalid, "simulated crash"
    end
    begin
      assert_raises(ActiveRecord::StatementInvalid) do
        capture_io { ShoplineOrdersRestoreRunner.apply(dedupe_run_id: run_id) }
      end
    ensure
      ShoplineOrdersRestoreService.singleton_class.send(:remove_method, :call)
      ShoplineOrdersRestoreService.define_singleton_method(:call, original)
    end

    run = SyncRun.latest_for("shopline_orders_restore")
    assert_equal "failed", run.status
    assert_equal "ActiveRecord::StatementInvalid", run.meta["error"]
  end

  test "meta contains no PII" do
    run_id = apply_dedupe_and_capture_run_id(order_number: "#RRN4")
    capture_io { ShoplineOrdersRestoreRunner.apply(dedupe_run_id: run_id) }

    meta_json = SyncRun.latest_for("shopline_orders_restore").meta.to_json
    assert_not_includes meta_json, "runner@example.com"
    assert_not_includes meta_json, "@example.com"
  end
end

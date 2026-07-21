# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/shopline_orders_dedupe_runner")

class ShoplineOrdersDedupeRunnerTest < ActiveSupport::TestCase
  def create_pair(order_number:, email: "runner@example.com")
    a = ShoplineOrder.create!(order_number: order_number, product_name: "薑黃6", quantity: 1,
                              checkout_amount: 10050, total_amount: 15830, payment_status: "已付款",
                              order_date: Time.current, import_run_id: 1, email: email)
    ShoplineOrder.create!(order_number: order_number, product_name: "薑黃6", quantity: 1,
                         checkout_amount: 10050, total_amount: nil, payment_status: "已付款",
                         order_date: a.order_date, import_run_id: 2, email: email)
  end

  test "dry_run writes no SyncRun" do
    create_pair(order_number: "#RN1")
    capture_io { ShoplineOrdersDedupeRunner.dry_run }

    assert_nil SyncRun.latest_for("shopline_orders_dedupe")
  end

  test "apply records a success SyncRun when the batch is clean" do
    create_pair(order_number: "#RN2")
    capture_io { ShoplineOrdersDedupeRunner.apply }

    run = SyncRun.latest_for("shopline_orders_dedupe")
    assert_equal "success", run.status
    assert run.finished_at.present?
    assert_equal 1, run.meta["candidate_delete_count"]
  end

  test "apply meta contains no email, name, or phone" do
    create_pair(order_number: "#RN3", email: "leak-me@example.com")
    capture_io { ShoplineOrdersDedupeRunner.apply }

    meta_json = SyncRun.latest_for("shopline_orders_dedupe").meta.to_json
    assert_not_includes meta_json, "leak-me@example.com"
    assert_not_includes meta_json, "@example.com"
  end

  test "apply with nothing to clean still records success" do
    capture_io { ShoplineOrdersDedupeRunner.apply }

    run = SyncRun.latest_for("shopline_orders_dedupe")
    assert_equal "success", run.status
    assert_equal 0, run.meta["candidate_delete_count"]
  end

  test "a crash inside the service still leaves a failed SyncRun and re-raises" do
    create_pair(order_number: "#RN4")

    original = ShoplineOrdersDedupeService.method(:call)
    ShoplineOrdersDedupeService.define_singleton_method(:call) do |*|
      raise ActiveRecord::StatementInvalid, "simulated crash"
    end
    begin
      assert_raises(ActiveRecord::StatementInvalid) do
        capture_io { ShoplineOrdersDedupeRunner.apply }
      end
    ensure
      ShoplineOrdersDedupeService.singleton_class.send(:remove_method, :call)
      ShoplineOrdersDedupeService.define_singleton_method(:call, original)
    end

    run = SyncRun.latest_for("shopline_orders_dedupe")
    assert_equal "failed", run.status
    assert_equal "ActiveRecord::StatementInvalid", run.meta["error"]
  end
end

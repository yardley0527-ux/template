# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/shopline_orders_rehash_runner")

class ShoplineOrdersRehashRunnerTest < ActiveSupport::TestCase
  def old_hash(order_number:, product_name:, quantity:, checkout_amount:, total_amount:)
    Digest::SHA256.hexdigest(
      JSON.generate(order_number: order_number.to_s.strip, product_name: product_name.to_s.strip,
                    quantity: quantity.to_i, checkout_amount: ShoplineOrder.format_decimal(checkout_amount),
                    total_amount: ShoplineOrder.format_decimal(total_amount))
    )
  end

  def create_with_old_hash(order_number:, product_name: "薑黃6", checkout_amount: 10050, total_amount: 15830)
    ShoplineOrder.create!(
      order_number: order_number, product_name: product_name, quantity: 1,
      checkout_amount: checkout_amount, total_amount: total_amount,
      payment_status: "已付款", order_date: 5.days.ago,
      source_row_hash: old_hash(order_number: order_number, product_name: product_name, quantity: 1,
                                checkout_amount: checkout_amount, total_amount: total_amount)
    )
  end

  test "dry_run writes no SyncRun" do
    create_with_old_hash(order_number: "#RR1")
    capture_io { ShoplineOrdersRehashRunner.dry_run }

    assert_nil SyncRun.latest_for("shopline_orders_rehash")
  end

  test "apply records a success SyncRun when the batch is clean" do
    create_with_old_hash(order_number: "#RR2")
    capture_io { ShoplineOrdersRehashRunner.apply }

    run = SyncRun.latest_for("shopline_orders_rehash")
    assert_equal "success", run.status
    assert run.finished_at.present?
    assert_equal 1, run.meta["changed_rows"]
  end

  test "apply with nothing to rehash still records success" do
    capture_io { ShoplineOrdersRehashRunner.apply }

    run = SyncRun.latest_for("shopline_orders_rehash")
    assert_equal "success", run.status
    assert_equal 0, run.meta["changed_rows"]
  end

  test "a collision-detected abort records a failed SyncRun with the reason, no crash" do
    create_with_old_hash(order_number: "#RR3", product_name: "薑黃6", checkout_amount: 10050, total_amount: 15830)
    create_with_old_hash(order_number: "#RR4", product_name: "全能1", checkout_amount: 1000, total_amount: 1000)

    original = ShoplineOrder.method(:content_hash)
    ShoplineOrder.define_singleton_method(:content_hash) { |**| "forced-collision" }
    begin
      capture_io { ShoplineOrdersRehashRunner.apply }
    ensure
      ShoplineOrder.singleton_class.send(:remove_method, :content_hash)
      ShoplineOrder.define_singleton_method(:content_hash, original)
    end

    run = SyncRun.latest_for("shopline_orders_rehash")
    assert_equal "failed", run.status
    assert_match(/collision_detected/, run.meta["reason"])
  end

  test "a crash inside the service still leaves a failed SyncRun and re-raises" do
    create_with_old_hash(order_number: "#RR5")

    original = ShoplineOrdersRehashService.method(:call)
    ShoplineOrdersRehashService.define_singleton_method(:call) do |*|
      raise ActiveRecord::StatementInvalid, "simulated crash"
    end
    begin
      assert_raises(ActiveRecord::StatementInvalid) do
        capture_io { ShoplineOrdersRehashRunner.apply }
      end
    ensure
      ShoplineOrdersRehashService.singleton_class.send(:remove_method, :call)
      ShoplineOrdersRehashService.define_singleton_method(:call, original)
    end

    run = SyncRun.latest_for("shopline_orders_rehash")
    assert_equal "failed", run.status
    assert_equal "ActiveRecord::StatementInvalid", run.meta["error"]
  end

  test "meta contains no PII (rehash reports never include email/order content)" do
    create_with_old_hash(order_number: "#RR6")
    capture_io { ShoplineOrdersRehashRunner.apply }

    meta_json = SyncRun.latest_for("shopline_orders_rehash").meta.to_json
    assert_not_includes meta_json, "@"
  end
end

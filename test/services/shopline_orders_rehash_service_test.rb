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

  # ── 完整 dry-run 統計 ─────────────────────────────────────────────

  test "dry-run reports the full required stat set" do
    create_with_old_hash(order_number: "#R7", product_name: "薑黃6",
                         checkout_amount: 10050, total_amount: 15830)
    ShoplineOrder.create!(order_number: "#R8", product_name: "私密粉1", quantity: 1, checkout_amount: 1980,
                         payment_status: "已付款", order_date: 1.day.ago,
                         source_row_hash: ShoplineOrder.content_hash(order_number: "#R8", product_name: "私密粉1",
                                                                     quantity: 1, checkout_amount: 1980, occurrence: 1))

    result = ShoplineOrdersRehashService.call(apply: false)

    assert_equal 2, result[:total_rows]
    assert_equal 1, result[:unchanged_rows]
    assert_equal 1, result[:changed_rows]
    assert_equal 0, result[:collision_groups]
    assert_equal 0, result[:collision_rows]
    assert_equal [], result[:duplicate_target_hashes]
    assert_equal 0, result[:rows_missing_required_identity]
    assert_equal 0, result[:ambiguous_occurrence_groups]
    # fixture rows never set import_run_id, so nil is correctly excluded from the count
    assert_equal 0, result[:affected_import_runs]
    assert_equal true, result[:safe_to_apply]
    assert result[:compute_seconds].is_a?(Numeric)
    assert result[:estimated_apply_seconds].is_a?(Numeric)
  end

  test "rows_missing_required_identity flags blank order_number/product_name/quantity" do
    ShoplineOrder.create!(order_number: "", product_name: "私密粉1", quantity: 1, checkout_amount: 1980,
                         payment_status: "已付款", order_date: 1.day.ago, source_row_hash: "x1")
    ShoplineOrder.create!(order_number: "#R9", product_name: "", quantity: 1, checkout_amount: 1980,
                         payment_status: "已付款", order_date: 1.day.ago, source_row_hash: "x2")
    ShoplineOrder.create!(order_number: "#R10", product_name: "私密粉1", quantity: nil, checkout_amount: 1980,
                         payment_status: "已付款", order_date: 1.day.ago, source_row_hash: "x3")

    result = ShoplineOrdersRehashService.call(apply: false)

    assert_equal 3, result[:rows_missing_required_identity]
  end

  test "affected_import_runs counts distinct import_run_id among changed rows" do
    a = create_with_old_hash(order_number: "#R11X", product_name: "薑黃6", checkout_amount: 10050, total_amount: 15830)
    b = create_with_old_hash(order_number: "#R11Y", product_name: "全能1", checkout_amount: 1000, total_amount: 1000)
    a.update_column(:import_run_id, 901)
    b.update_column(:import_run_id, 902)

    result = ShoplineOrdersRehashService.call(apply: false)

    assert_equal 2, result[:affected_import_runs]
  end

  test "ambiguous_occurrence_groups counts signature groups with more than one row" do
    create_with_old_hash(order_number: "#R11", product_name: "薑黃6", checkout_amount: 10050, total_amount: 15830)
    create_with_old_hash(order_number: "#R11", product_name: "薑黃6", checkout_amount: 10050, total_amount: nil)
    create_with_old_hash(order_number: "#R12", product_name: "全能1", checkout_amount: 1000, total_amount: 1000)

    result = ShoplineOrdersRehashService.call(apply: false)

    assert_equal 1, result[:ambiguous_occurrence_groups]
  end

  # ── Collision 防護：apply 前重新計算，非零時拒絕執行 ──────────────

  test "apply refuses to write and aborts when a collision is (forcibly) detected" do
    create_with_old_hash(order_number: "#R13", product_name: "薑黃6", checkout_amount: 10050, total_amount: 15830)
    create_with_old_hash(order_number: "#R14", product_name: "全能1", checkout_amount: 1000, total_amount: 1000)

    original = ShoplineOrder.method(:content_hash)
    ShoplineOrder.define_singleton_method(:content_hash) { |**| "forced-collision" }
    begin
      result = ShoplineOrdersRehashService.call(apply: true)
    ensure
      ShoplineOrder.singleton_class.send(:remove_method, :content_hash)
      ShoplineOrder.define_singleton_method(:content_hash, original)
    end

    assert_equal false, result[:applied]
    assert result[:aborted]
    assert_match(/collision_detected/, result[:abort_reason])
    assert_equal 1, result[:collision_groups]
    assert_equal 2, result[:collision_rows]
    # 沒有任何列被實際改寫
    assert_not_equal "forced-collision", ShoplineOrder.find_by!(order_number: "#R13").source_row_hash
  end

  test "dry-run also reports a forced collision without writing (safe_to_apply is false)" do
    create_with_old_hash(order_number: "#R15", product_name: "薑黃6", checkout_amount: 10050, total_amount: 15830)
    create_with_old_hash(order_number: "#R16", product_name: "全能1", checkout_amount: 1000, total_amount: 1000)

    original = ShoplineOrder.method(:content_hash)
    ShoplineOrder.define_singleton_method(:content_hash) { |**| "forced-collision" }
    begin
      result = ShoplineOrdersRehashService.call(apply: false)
    ensure
      ShoplineOrder.singleton_class.send(:remove_method, :content_hash)
      ShoplineOrder.define_singleton_method(:content_hash, original)
    end

    assert_equal false, result[:safe_to_apply]
    assert_equal 1, result[:collision_groups]
  end

  test "apply verification reports clean state and zero collisions after a normal run" do
    create_with_old_hash(order_number: "#R17", product_name: "薑黃6", checkout_amount: 10050, total_amount: 15830)

    result = ShoplineOrdersRehashService.call(apply: true)

    assert result[:verification][:clean]
    assert_equal 0, result[:verification][:rows_still_pending]
    assert_equal 0, result[:verification][:collisions_after_apply]
  end

  # ── advisory lock（共用鎖，與 dedupe/importer 互斥） ────────────────

  test "apply aborts without writing when the shared maintenance lock is held elsewhere" do
    create_with_old_hash(order_number: "#R18", product_name: "薑黃6", checkout_amount: 10050, total_amount: 15830)

    db_config = ActiveRecord::Base.connection_db_config.configuration_hash
    other = PG.connect(dbname: db_config[:database], host: db_config[:host],
                       port: db_config[:port], user: db_config[:username], password: db_config[:password])
    other.exec("SELECT pg_advisory_lock(hashtext('shopline_orders_write'))")
    begin
      result = ShoplineOrdersRehashService.call(apply: true)
      assert result[:aborted]
      assert_match(/lock_busy/, result[:abort_reason])
    ensure
      other.exec("SELECT pg_advisory_unlock(hashtext('shopline_orders_write'))")
      other.close
    end

    row = ShoplineOrder.find_by!(order_number: "#R18")
    assert_not_equal ShoplineOrder.content_hash(order_number: "#R18", product_name: "薑黃6", quantity: 1,
                                                checkout_amount: 10050, occurrence: 1), row.source_row_hash,
      "must not have written while the lock was held elsewhere"
  end

  test "dry-run does not need the lock and still works while apply lock is held elsewhere" do
    create_with_old_hash(order_number: "#R19", product_name: "薑黃6", checkout_amount: 10050, total_amount: 15830)

    db_config = ActiveRecord::Base.connection_db_config.configuration_hash
    other = PG.connect(dbname: db_config[:database], host: db_config[:host],
                       port: db_config[:port], user: db_config[:username], password: db_config[:password])
    other.exec("SELECT pg_advisory_lock(hashtext('shopline_orders_write'))")
    begin
      result = ShoplineOrdersRehashService.call(apply: false)
      assert_equal 1, result[:changed_rows]
      assert_not result[:aborted]
    ensure
      other.exec("SELECT pg_advisory_unlock(hashtext('shopline_orders_write'))")
      other.close
    end
  end
end

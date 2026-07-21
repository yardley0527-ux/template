# frozen_string_literal: true

require "test_helper"

class ShoplineOrdersRestoreServiceTest < ActiveSupport::TestCase
  def apply_dedupe_and_capture_run_id(order_number:, email: "restore@example.com")
    a = ShoplineOrder.create!(order_number: order_number, product_name: "薑黃6", quantity: 1,
                              checkout_amount: 10050, total_amount: 15830, payment_status: "已付款",
                              order_date: Time.current, import_run_id: 1, email: email)
    ShoplineOrder.create!(order_number: order_number, product_name: "薑黃6", quantity: 1,
                         checkout_amount: 10050, total_amount: nil, payment_status: "已付款",
                         order_date: a.order_date, import_run_id: 2, email: email)

    dedupe_report = ShoplineOrdersDedupeService.call(apply: true)
    [dedupe_report[:dedupe_run_id], a.id]
  end

  # ── apply dedupe → restore → 資料完全回到原狀 ─────────────────────

  test "apply dedupe then restore brings the deleted row's content back" do
    run_id, kept_id = apply_dedupe_and_capture_run_id(order_number: "#RS1")
    assert_equal 1, ShoplineOrder.where(order_number: "#RS1").count

    result = ShoplineOrdersRestoreService.call(dedupe_run_id: run_id, apply: true)

    assert_equal true, result[:applied]
    assert_equal 1, result[:restored_count]
    orders = ShoplineOrder.where(order_number: "#RS1").order(:id)
    assert_equal 2, orders.count
    assert ShoplineOrder.exists?(kept_id), "the never-deleted row must still be present"

    restored = orders.where.not(id: kept_id).first
    assert_equal 10050, restored.checkout_amount.to_i
    assert_nil restored.total_amount
    assert_equal "restore@example.com", restored.email
    assert_match(/\Arestored:/, restored.source_row_hash)
  end

  test "restore report never includes email/name/phone" do
    run_id, = apply_dedupe_and_capture_run_id(order_number: "#RS2", email: "leak-restore@example.com")

    result = ShoplineOrdersRestoreService.call(dedupe_run_id: run_id, apply: false)

    assert_not_includes result.to_s, "leak-restore@example.com"
    assert_equal 1, result[:affected_customers]
    assert_equal 1, result[:affected_orders]
  end

  # ── restore 重跑（冪等）─────────────────────────────────────────

  test "restoring the same run_id twice only restores once" do
    run_id, = apply_dedupe_and_capture_run_id(order_number: "#RS3")

    first  = ShoplineOrdersRestoreService.call(dedupe_run_id: run_id, apply: true)
    second = ShoplineOrdersRestoreService.call(dedupe_run_id: run_id, apply: true)

    assert_equal 1, first[:restored_count]
    assert_equal 0, second[:restored_count]
    assert_equal 2, ShoplineOrder.where(order_number: "#RS3").count, "must not restore a 3rd time"
  end

  # ── 指定錯誤 run id ─────────────────────────────────────────────

  test "an unknown dedupe_run_id restores nothing and does not error" do
    result = ShoplineOrdersRestoreService.call(dedupe_run_id: "not-a-real-run-id", apply: true)

    assert_equal true, result[:applied]
    assert_equal 0, result[:restored_count]
    assert_equal 0, result[:total_backed_up]
  end

  # ── 部分資料已存在（部分已 restore 過）───────────────────────────

  test "when some backups in a run are already restored, only the remaining ones are restored" do
    run_id, = apply_dedupe_and_capture_run_id(order_number: "#RS4")
    second_pair_run_id, = apply_dedupe_and_capture_run_id(order_number: "#RS5")
    # 強行讓兩組落在同一個 dedupe_run_id 下，模擬「這批裡有一筆已回復過」
    ShoplineOrdersDedupeBackup.where(dedupe_run_id: second_pair_run_id).update_all(dedupe_run_id: run_id)

    ShoplineOrdersDedupeBackup.where(dedupe_run_id: run_id).first.update!(restored_at: 1.hour.ago)

    result = ShoplineOrdersRestoreService.call(dedupe_run_id: run_id, apply: true)

    assert_equal 1, result[:restored_count]
    assert_equal 2, ShoplineOrdersDedupeBackup.where(dedupe_run_id: run_id).count
  end

  # ── transaction rollback ────────────────────────────────────────

  test "a failure mid-restore rolls back the whole batch" do
    run_id, = apply_dedupe_and_capture_run_id(order_number: "#RS6")

    original = ShoplineOrder.method(:create!)
    ShoplineOrder.define_singleton_method(:create!) { |*| raise ActiveRecord::StatementInvalid, "boom" }
    begin
      assert_raises(ActiveRecord::StatementInvalid) do
        ShoplineOrdersRestoreService.call(dedupe_run_id: run_id, apply: true)
      end
    ensure
      ShoplineOrder.singleton_class.send(:remove_method, :create!)
      ShoplineOrder.define_singleton_method(:create!, original)
    end

    assert_equal 1, ShoplineOrder.where(order_number: "#RS6").count, "no row should have been restored"
    assert_nil ShoplineOrdersDedupeBackup.find_by(dedupe_run_id: run_id).restored_at
  end

  # ── advisory lock（共用鎖）───────────────────────────────────────

  test "apply aborts without writing when the shared maintenance lock is held elsewhere" do
    run_id, = apply_dedupe_and_capture_run_id(order_number: "#RS7")

    db_config = ActiveRecord::Base.connection_db_config.configuration_hash
    other = PG.connect(dbname: db_config[:database], host: db_config[:host],
                       port: db_config[:port], user: db_config[:username], password: db_config[:password])
    other.exec("SELECT pg_advisory_lock(hashtext('shopline_orders_write'))")
    begin
      result = ShoplineOrdersRestoreService.call(dedupe_run_id: run_id, apply: true)
      assert result[:aborted]
      assert_equal 1, ShoplineOrder.where(order_number: "#RS7").count
    ensure
      other.exec("SELECT pg_advisory_unlock(hashtext('shopline_orders_write'))")
      other.close
    end
  end

  test "dry-run does not need the lock" do
    run_id, = apply_dedupe_and_capture_run_id(order_number: "#RS8")

    db_config = ActiveRecord::Base.connection_db_config.configuration_hash
    other = PG.connect(dbname: db_config[:database], host: db_config[:host],
                       port: db_config[:port], user: db_config[:username], password: db_config[:password])
    other.exec("SELECT pg_advisory_lock(hashtext('shopline_orders_write'))")
    begin
      result = ShoplineOrdersRestoreService.call(dedupe_run_id: run_id, apply: false)
      assert_not result[:aborted]
      assert_equal 1, result[:pending_restore_count]
    ensure
      other.exec("SELECT pg_advisory_unlock(hashtext('shopline_orders_write'))")
      other.close
    end
  end

  test "verification block confirms restored rows and marked backups" do
    run_id, = apply_dedupe_and_capture_run_id(order_number: "#RS9")

    result = ShoplineOrdersRestoreService.call(dedupe_run_id: run_id, apply: true)

    assert result[:verification][:restored_ids_present]
    assert result[:verification][:backups_marked_restored]
  end
end

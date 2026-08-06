# frozen_string_literal: true

require "test_helper"

# Phase 3 開始前的驗證：新訂單進來後、在下一次 refresh 跑之前，active task
# 是否會提早消失或重複？refresh 跑完之後，新 cycle 是否正確接手、舊 cycle
# 是否正確退場？用真正的 CrmCustomerProductCycleBuilderService 跑，不是手動
# 建構 cycle fixture，才能驗證到真實的 upsert/去重邏輯。
class CrmCustomerProductCycleLifecycleTest < ActiveSupport::TestCase
  def unique_key
    "lifecycle_#{SecureRandom.hex(4)}"
  end

  def make_product(key, label, medians: { 1 => 60 })
    product = CrmProduct.create!(key: key, label: label, status: "confirmed",
                                  sql_pattern: "product_name LIKE '%#{label}%'", regex_pattern: "#{label}(\\d+)")
    medians.each { |bottles, days| CrmRepurchaseCycleConfig.create!(product_key: key, bottle_count: bottles, median_days: days, source: "manual") }
    product
  end

  def make_order(email:, product_name:, order_date:, order_number: nil)
    ShoplineOrder.create!(
      order_number: order_number || "ORD#{SecureRandom.hex(6)}", email: email, product_name: product_name,
      order_date: order_date, payment_status: "已付款", quantity: 1
    )
  end

  test "1. 最新 cycle 一開始配對到同品回購前，先確認初始建置正確" do
    key = unique_key
    make_product(key, "測試生命週期甲")
    email = "buyer_#{SecureRandom.hex(4)}@example.com"
    make_order(email: email, product_name: "測試生命週期甲1", order_date: Date.new(2026, 1, 1))

    CrmCustomerProductCycleBuilderService.call(product_key: key)

    identity_key = ShoplineOrder.find_by(email: email).email.downcase
    cycle = CrmCustomerProductCycle.find_by(product_key: key, cycle_started_at: Date.new(2026, 1, 1))
    assert_equal "not_yet_repurchased", cycle.match_status
    assert_includes CrmCustomerProductCycle.active_follow_up.pluck(:id), cycle.id
  end

  test "2→5. 新訂單存在但 refresh 未跑：舊 cycle 仍是 active；refresh 後新 cycle 接手，舊 cycle 退場" do
    key = unique_key
    make_product(key, "測試生命週期乙")
    email = "buyer_#{SecureRandom.hex(4)}@example.com"

    make_order(email: email, product_name: "測試生命週期乙1", order_date: Date.new(2026, 1, 1))
    CrmCustomerProductCycleBuilderService.call(product_key: key)

    old_cycle = CrmCustomerProductCycle.find_by(product_key: key, cycle_started_at: Date.new(2026, 1, 1))

    # ── 2. 新訂單已經寫進 shopline_orders，但還沒有跑第二次 refresh ──
    make_order(email: email, product_name: "測試生命週期乙1", order_date: Date.new(2026, 3, 1))

    # 這個時間點：舊 cycle 必須仍然是唯一的 active task，不能提早消失、
    # 也不能因為新訂單存在就出現第二筆（builder 還沒跑，資料庫裡就是只有一筆）。
    active_ids_before_refresh = CrmCustomerProductCycle.where(product_key: key).active_follow_up.pluck(:id)
    assert_equal [old_cycle.id], active_ids_before_refresh
    assert_equal 1, CrmCustomerProductCycle.where(product_key: key).count

    # ── 3. 執行 refresh ──
    CrmCustomerProductCycleBuilderService.call(product_key: key)

    # ── 4. 新 cycle 建立，且正確成為 active task ──
    new_cycle = CrmCustomerProductCycle.find_by(product_key: key, cycle_started_at: Date.new(2026, 3, 1))
    assert new_cycle.present?, "refresh 後應該建立第二個 cycle"
    assert_equal "not_yet_repurchased", new_cycle.match_status

    active_ids_after_refresh = CrmCustomerProductCycle.where(product_key: key).active_follow_up.pluck(:id)
    assert_equal [new_cycle.id], active_ids_after_refresh

    # ── 5. 舊 cycle 不會重新出現（歷史保留，但不再是 active）──
    old_cycle.reload
    assert_equal "same_product_repurchase", old_cycle.match_status
    assert_not_includes active_ids_after_refresh, old_cycle.id

    # 重跑 refresh 多次，結果穩定不漂移（冪等，呼應 Phase 1.5 的規則）
    CrmCustomerProductCycleBuilderService.call(product_key: key)
    assert_equal [new_cycle.id], CrmCustomerProductCycle.where(product_key: key).active_follow_up.pluck(:id)
    assert_equal 2, CrmCustomerProductCycle.where(product_key: key).count
  end
end

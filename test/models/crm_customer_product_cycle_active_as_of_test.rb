# frozen_string_literal: true

require "test_helper"

# Phase 3.1: CrmCustomerProductCycle.active_as_of(reference_date)——歷史直播
# 名單重建用的「以某天為基準的 active task」，跟 active_follow_up（現在）
# 是兩個不同、刻意分開的方法，這裡只驗證這個新方法本身，不動 Phase 2 既有測試。
class CrmCustomerProductCycleActiveAsOfTest < ActiveSupport::TestCase
  def build_cycle(overrides = {})
    CrmCustomerProductCycle.create!({
      identity_key: "asof_#{SecureRandom.hex(4)}",
      email: "asof@example.com",
      product_key: "omnipotent",
      cycle_started_at: Date.new(2026, 1, 1),
      bottle_count: 3,
      estimated_usage_days: 60,
      estimated_finish_date: Date.new(2026, 3, 2),
      suggested_contact_date: Date.new(2026, 2, 23),
      match_status: "not_yet_repurchased",
      refreshed_at: Time.current
    }.merge(overrides))
  end

  test "只看 cycle_started_at 不晚於參考日的週期" do
    identity_key = "cutoff_#{SecureRandom.hex(4)}"
    before = build_cycle(identity_key: identity_key, cycle_started_at: Date.new(2026, 1, 1))
    build_cycle(identity_key: identity_key, cycle_started_at: Date.new(2026, 7, 1)) # 晚於參考日

    ids = CrmCustomerProductCycle.active_as_of(Date.new(2026, 6, 1)).where(identity_key: identity_key).pluck(:id)
    assert_equal [before.id], ids
  end

  test "同一組 identity_key+product_key，參考日以前最新的一筆勝出" do
    identity_key = "latest_asof_#{SecureRandom.hex(4)}"
    build_cycle(identity_key: identity_key, cycle_started_at: Date.new(2026, 1, 1))
    latest = build_cycle(identity_key: identity_key, cycle_started_at: Date.new(2026, 4, 1))

    ids = CrmCustomerProductCycle.active_as_of(Date.new(2026, 6, 1)).where(identity_key: identity_key).pluck(:id)
    assert_equal [latest.id], ids
  end

  test "next_same_product_order_date 晚於參考日不算「當時已回購」，不排除" do
    cycle = build_cycle(next_same_product_order_date: Date.new(2026, 7, 1))
    assert_includes CrmCustomerProductCycle.active_as_of(Date.new(2026, 6, 1)).pluck(:id), cycle.id
  end

  test "next_same_product_order_date 早於或等於參考日代表當時已回購，排除" do
    cycle = build_cycle(next_same_product_order_date: Date.new(2026, 5, 1))
    assert_not_includes CrmCustomerProductCycle.active_as_of(Date.new(2026, 6, 1)).pluck(:id), cycle.id

    on_boundary = build_cycle(next_same_product_order_date: Date.new(2026, 6, 1))
    assert_not_includes CrmCustomerProductCycle.active_as_of(Date.new(2026, 6, 1)).pluck(:id), on_boundary.id
  end
end

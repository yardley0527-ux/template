# frozen_string_literal: true

require "test_helper"

# Phase 2：active_follow_up projection（Dashboard 的「一位顧客 × 一項產品 ×
# 一筆目前有效任務」去重規則）+ 狀態篩選/排序的 SQL 定義。
class CrmCustomerProductCycleActiveFollowUpTest < ActiveSupport::TestCase
  def build_cycle(overrides = {})
    CrmCustomerProductCycle.create!({
      identity_key: "test_#{SecureRandom.hex(4)}",
      email: "test@example.com",
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

  test "同一顧客同一產品多個 cycle，active_follow_up 只回傳最新一筆" do
    identity_key = "dedup_#{SecureRandom.hex(4)}"
    older = build_cycle(identity_key: identity_key, cycle_started_at: Date.new(2026, 1, 1),
                         match_status: "same_product_repurchase",
                         next_same_product_order_date: Date.new(2026, 3, 5))
    newer = build_cycle(identity_key: identity_key, cycle_started_at: Date.new(2026, 3, 5))

    ids = CrmCustomerProductCycle.active_follow_up.where(identity_key: identity_key).pluck(:id)
    assert_equal [newer.id], ids
    assert_not_includes ids, older.id
  end

  test "已完成同品回購的舊週期不會出現在待辦（防禦性：即使它是目前唯一/最新一列）" do
    identity_key = "resolved_only_#{SecureRandom.hex(4)}"
    build_cycle(identity_key: identity_key, match_status: "same_product_repurchase",
                next_same_product_order_date: Date.new(2026, 3, 5))

    ids = CrmCustomerProductCycle.active_follow_up.where(identity_key: identity_key).pluck(:id)
    assert_empty ids
  end

  test "加購造成的相鄰週期不會產生兩筆待辦" do
    identity_key = "addon_dedup_#{SecureRandom.hex(4)}"
    original = build_cycle(identity_key: identity_key, cycle_started_at: Date.new(2026, 1, 1),
                            match_status: "same_product_addon",
                            next_same_product_order_date: Date.new(2026, 1, 10))
    addon_cycle = build_cycle(identity_key: identity_key, cycle_started_at: Date.new(2026, 1, 10))

    ids = CrmCustomerProductCycle.active_follow_up.where(identity_key: identity_key).pluck(:id)
    assert_equal [addon_cycle.id], ids
    assert_not_includes ids, original.id
  end

  test "follow_up_status 為 nil（多數 cycle 的預設狀態）不會被預設隱藏清單排除" do
    # 這條測試專門攔截 where.not(hash) 對 NULL 欄位的 SQL 三值邏輯陷阱
    cycle = build_cycle(follow_up_status: nil)
    query = CrmRepurchaseDashboardQuery.new({})
    assert_includes query.cycles.map(&:id), cycle.id
  end

  test "paused／repurchased 預設被隱藏，但用狀態篩選找得到" do
    paused = build_cycle(identity_key: "paused_#{SecureRandom.hex(4)}", follow_up_status: "paused")
    repurchased = build_cycle(identity_key: "repurchased_#{SecureRandom.hex(4)}", follow_up_status: "repurchased")

    default_query = CrmRepurchaseDashboardQuery.new({})
    default_ids = default_query.cycles.map(&:id)
    assert_not_includes default_ids, paused.id
    assert_not_includes default_ids, repurchased.id

    paused_query = CrmRepurchaseDashboardQuery.new({ status: "paused" })
    assert_includes paused_query.cycles.map(&:id), paused.id

    repurchased_query = CrmRepurchaseDashboardQuery.new({ status: "repurchased" })
    assert_includes repurchased_query.cycles.map(&:id), repurchased.id
  end

  test "remaining_days_sql（SQL）跟 effective_remaining_days（Ruby）在有／無人工覆寫時結果一致" do
    travel_to Date.new(2026, 2, 1) do
      plain    = build_cycle(estimated_finish_date: Date.new(2026, 2, 20))
      override_days = build_cycle(identity_key: "ov_days_#{SecureRandom.hex(4)}",
                                   manual_override_remaining_days: 5, manual_override_at: Time.current)
      override_date = build_cycle(identity_key: "ov_date_#{SecureRandom.hex(4)}",
                                   manual_override_finish_date: Date.new(2026, 4, 1))

      [plain, override_days, override_date].each do |cycle|
        sql_value = CrmCustomerProductCycle
          .where(id: cycle.id)
          .pick(Arel.sql(CrmCustomerProductCycle.remaining_days_sql(reference_date: Date.current)))
        assert_equal cycle.effective_remaining_days, sql_value, "SQL/Ruby remaining_days 不一致：#{cycle.identity_key}"
      end
    end
  end

  test "with_status_filter 涵蓋 7 種狀態，各自篩到正確的 cycle" do
    travel_to Date.new(2026, 3, 1) do
      overdue    = build_cycle(identity_key: "s_overdue_#{SecureRandom.hex(4)}", estimated_finish_date: Date.new(2026, 2, 20))
      due_today  = build_cycle(identity_key: "s_due_today_#{SecureRandom.hex(4)}", estimated_finish_date: Date.new(2026, 3, 1))
      due_soon   = build_cycle(identity_key: "s_due_soon_#{SecureRandom.hex(4)}", estimated_finish_date: Date.new(2026, 3, 5))
      tracking   = build_cycle(identity_key: "s_tracking_#{SecureRandom.hex(4)}", estimated_finish_date: Date.new(2026, 4, 1))
      waiting    = build_cycle(identity_key: "s_wait_#{SecureRandom.hex(4)}", follow_up_status: "waiting_reply")
      resched    = build_cycle(identity_key: "s_resched_#{SecureRandom.hex(4)}", follow_up_status: "rescheduled")
      paused     = build_cycle(identity_key: "s_paused_#{SecureRandom.hex(4)}", follow_up_status: "paused")
      repurchased = build_cycle(identity_key: "s_repurchased_#{SecureRandom.hex(4)}", follow_up_status: "repurchased")

      base = CrmCustomerProductCycle.where(id: [overdue, due_today, due_soon, tracking, waiting, resched, paused, repurchased].map(&:id))

      assert_equal [overdue.id],     CrmCustomerProductCycle.with_status_filter(base, "overdue").pluck(:id)
      assert_equal [due_today.id],   CrmCustomerProductCycle.with_status_filter(base, "due_today").pluck(:id)
      assert_equal [due_soon.id],    CrmCustomerProductCycle.with_status_filter(base, "due_soon").pluck(:id)
      assert_equal [waiting.id],     CrmCustomerProductCycle.with_status_filter(base, "waiting_reply").pluck(:id)
      assert_equal [resched.id],     CrmCustomerProductCycle.with_status_filter(base, "rescheduled").pluck(:id)
      assert_equal [paused.id],      CrmCustomerProductCycle.with_status_filter(base, "paused").pluck(:id)
      assert_equal [repurchased.id], CrmCustomerProductCycle.with_status_filter(base, "repurchased").pluck(:id)

      assert_equal "overdue",       overdue.derived_status
      assert_equal "due_today",     due_today.derived_status
      assert_equal "due_soon",      due_soon.derived_status
      assert_equal "tracking",      tracking.derived_status
      assert_equal "waiting_reply", waiting.derived_status
    end
  end
end

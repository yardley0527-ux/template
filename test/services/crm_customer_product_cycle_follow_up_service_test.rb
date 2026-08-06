# frozen_string_literal: true

require "test_helper"

class CrmCustomerProductCycleFollowUpServiceTest < ActiveSupport::TestCase
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

  def actor
    users(:one)
  end

  test "contacted_waiting_reply sets follow_up_status and creates a history event" do
    cycle = build_cycle
    event = CrmCustomerProductCycleFollowUpService.call(cycle: cycle, actor: actor, action: "contacted_waiting_reply", note: "已致電")

    cycle.reload
    assert_equal "waiting_reply", cycle.follow_up_status
    assert cycle.last_contacted_at.present?

    assert_equal cycle, event.cycle
    assert_equal actor, event.performed_by
    assert_equal "contacted_waiting_reply", event.action
    assert_equal "已致電", event.note
  end

  test "rescheduled requires next_contact_date" do
    cycle = build_cycle
    assert_raises(CrmCustomerProductCycleFollowUpService::InvalidActionError) do
      CrmCustomerProductCycleFollowUpService.call(cycle: cycle, actor: actor, action: "rescheduled")
    end
  end

  test "rescheduled with next_contact_date sets follow_up_status and next_contact_date" do
    cycle = build_cycle
    CrmCustomerProductCycleFollowUpService.call(cycle: cycle, actor: actor, action: "rescheduled", next_contact_date: Date.new(2026, 3, 15))

    cycle.reload
    assert_equal "rescheduled", cycle.follow_up_status
    assert_equal Date.new(2026, 3, 15), cycle.next_contact_date
  end

  test "not_yet_finished requires remaining_days or next_contact_date" do
    cycle = build_cycle
    assert_raises(CrmCustomerProductCycleFollowUpService::InvalidActionError) do
      CrmCustomerProductCycleFollowUpService.call(cycle: cycle, actor: actor, action: "not_yet_finished")
    end
  end

  test "not_yet_finished with remaining_days applies manual override and clears follow_up_status back to date-driven" do
    cycle = build_cycle(follow_up_status: "waiting_reply")
    travel_to Date.new(2026, 2, 1) do
      CrmCustomerProductCycleFollowUpService.call(cycle: cycle, actor: actor, action: "not_yet_finished", remaining_days: 10)
    end

    cycle.reload
    assert_nil cycle.follow_up_status
    assert_equal 10, cycle.manual_override_remaining_days
    assert_match(/^follow_up:/, cycle.manual_override_source)
  end

  test "not_yet_finished with only next_contact_date sets rescheduled (no override)" do
    cycle = build_cycle
    CrmCustomerProductCycleFollowUpService.call(cycle: cycle, actor: actor, action: "not_yet_finished", next_contact_date: Date.new(2026, 4, 1))

    cycle.reload
    assert_equal "rescheduled", cycle.follow_up_status
    assert_equal Date.new(2026, 4, 1), cycle.next_contact_date
    assert_nil cycle.manual_override_remaining_days
  end

  test "not_needed and paused both set follow_up_status to paused" do
    cycle_a = build_cycle
    cycle_b = build_cycle(identity_key: "paused_b_#{SecureRandom.hex(4)}")

    CrmCustomerProductCycleFollowUpService.call(cycle: cycle_a, actor: actor, action: "not_needed")
    CrmCustomerProductCycleFollowUpService.call(cycle: cycle_b, actor: actor, action: "paused")

    assert_equal "paused", cycle_a.reload.follow_up_status
    assert_equal "paused", cycle_b.reload.follow_up_status
  end

  test "no_response sets waiting_reply, same as contacted_waiting_reply" do
    cycle = build_cycle
    CrmCustomerProductCycleFollowUpService.call(cycle: cycle, actor: actor, action: "no_response")
    assert_equal "waiting_reply", cycle.reload.follow_up_status
  end

  test "note_only logs a note without changing follow_up_status" do
    cycle = build_cycle(follow_up_status: "waiting_reply")
    CrmCustomerProductCycleFollowUpService.call(cycle: cycle, actor: actor, action: "note_only", note: "客戶說在國外")

    cycle.reload
    assert_equal "waiting_reply", cycle.follow_up_status
    assert_equal "客戶說在國外", cycle.follow_up_events.last.note
  end

  test "reassigning assigned_to_user_id works alongside any action" do
    cycle = build_cycle
    other = users(:two)
    CrmCustomerProductCycleFollowUpService.call(cycle: cycle, actor: actor, action: "note_only", assigned_to_user_id: other.id)

    assert_equal other.id, cycle.reload.assigned_to_user_id
  end

  test "repurchased with a system-detected order snapshots detected_order_number on the event" do
    cycle = build_cycle(next_same_product_order_number: "ORD999", next_same_product_order_date: Date.new(2026, 3, 1))
    event = CrmCustomerProductCycleFollowUpService.call(cycle: cycle, actor: actor, action: "repurchased")

    assert_equal "repurchased", cycle.reload.follow_up_status
    assert_equal "ORD999", event.detected_order_number
  end

  test "repurchased without a system-detected order records nil detected_order_number (人工確認，不偽造 order_id)" do
    cycle = build_cycle # next_same_product_order_number/date 皆為 nil
    event = CrmCustomerProductCycleFollowUpService.call(cycle: cycle, actor: actor, action: "repurchased")

    assert_equal "repurchased", cycle.reload.follow_up_status
    assert_nil event.detected_order_number
  end

  test "raises on unknown action" do
    cycle = build_cycle
    assert_raises(CrmCustomerProductCycleFollowUpService::InvalidActionError) do
      CrmCustomerProductCycleFollowUpService.call(cycle: cycle, actor: actor, action: "not_a_real_action")
    end
  end

  test "raises without an actor" do
    cycle = build_cycle
    assert_raises(CrmCustomerProductCycleFollowUpService::InvalidActionError) do
      CrmCustomerProductCycleFollowUpService.call(cycle: cycle, actor: nil, action: "note_only")
    end
  end

  test "every successful action creates exactly one follow_up_event" do
    cycle = build_cycle
    assert_difference -> { cycle.follow_up_events.count }, 1 do
      CrmCustomerProductCycleFollowUpService.call(cycle: cycle, actor: actor, action: "contacted_waiting_reply")
    end
  end
end

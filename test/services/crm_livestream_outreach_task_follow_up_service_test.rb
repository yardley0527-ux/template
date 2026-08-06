# frozen_string_literal: true

require "test_helper"

class CrmLivestreamOutreachTaskFollowUpServiceTest < ActiveSupport::TestCase
  def make_product(key, label)
    CrmProduct.create!(key: key, label: label, status: "confirmed",
                        sql_pattern: "product_name LIKE '%#{label}%'", regex_pattern: "#{label}(\\d+)")
    CrmRepurchaseCycleConfig.create!(product_key: key, bottle_count: 1, median_days: 60, source: "manual")
  end

  def build_cycle(overrides = {})
    CrmCustomerProductCycle.create!({
      identity_key: "task_svc_#{SecureRandom.hex(4)}",
      email: "task_svc@example.com",
      product_key: "omnipotent",
      cycle_started_at: Date.new(2026, 1, 1),
      bottle_count: 1,
      estimated_usage_days: 60,
      estimated_finish_date: Date.new(2026, 5, 1),
      suggested_contact_date: Date.new(2026, 4, 24),
      match_status: "not_yet_repurchased",
      refreshed_at: Time.current
    }.merge(overrides))
  end

  def build_task(cycle, livestream)
    CrmLivestreamOutreachTask.create!(
      livestream: livestream, cycle: cycle, identity_key: cycle.identity_key,
      assigned_to_user_id: users(:one).id, scheduled_date: Date.new(2026, 6, 1),
      status: "pending", candidate_reason: "win_back_1_30", hit_summary: [], created_by: users(:one)
    )
  end

  def actor
    users(:one)
  end

  test "一般操作（例如已聯絡等待回覆）會建立 follow_up_event（含 livestream_id）並把任務標記完成" do
    key = "tfu_#{SecureRandom.hex(4)}"
    make_product(key, "測試甲")
    livestream = Livestream.create!(date: Date.new(2026, 6, 1), title: "t", product_keys: [key])
    cycle = build_cycle(product_key: key)
    task  = build_task(cycle, livestream)

    event = CrmLivestreamOutreachTaskFollowUpService.call(task: task, actor: actor, action: "contacted_waiting_reply", note: "測試")

    assert_equal livestream.id, event.livestream_id
    task.reload
    assert_equal "completed", task.status
    assert task.completed_at.present?
    assert_equal "waiting_reply", cycle.reload.follow_up_status
  end

  test "純備註（note_only）不會自動完成任務" do
    key = "tfu_#{SecureRandom.hex(4)}"
    make_product(key, "測試乙")
    livestream = Livestream.create!(date: Date.new(2026, 6, 1), title: "t", product_keys: [key])
    cycle = build_cycle(product_key: key)
    task  = build_task(cycle, livestream)

    CrmLivestreamOutreachTaskFollowUpService.call(task: task, actor: actor, action: "note_only", note: "只是備註")

    assert_equal "pending", task.reload.status
    assert_nil task.completed_at
  end

  test "指定日期再聯絡：更新同一筆任務的排程日期，不會產生第二筆有效任務" do
    key = "tfu_#{SecureRandom.hex(4)}"
    make_product(key, "測試丙")
    livestream = Livestream.create!(date: Date.new(2026, 6, 1), title: "t", product_keys: [key])
    cycle = build_cycle(product_key: key)
    task  = build_task(cycle, livestream)

    assert_no_difference -> { CrmLivestreamOutreachTask.where(livestream_id: livestream.id, identity_key: cycle.identity_key).count } do
      CrmLivestreamOutreachTaskFollowUpService.call(
        task: task, actor: actor, action: "rescheduled", next_contact_date: Date.new(2026, 6, 15)
      )
    end

    task.reload
    assert_equal "pending", task.status
    assert_equal Date.new(2026, 6, 15), task.scheduled_date
  end

  test "「尚未吃完」只給 next_contact_date（不給 remaining_days）也視為改期，不完成任務" do
    key = "tfu_#{SecureRandom.hex(4)}"
    make_product(key, "測試丁")
    livestream = Livestream.create!(date: Date.new(2026, 6, 1), title: "t", product_keys: [key])
    cycle = build_cycle(product_key: key)
    task  = build_task(cycle, livestream)

    CrmLivestreamOutreachTaskFollowUpService.call(
      task: task, actor: actor, action: "not_yet_finished", next_contact_date: Date.new(2026, 6, 20)
    )

    task.reload
    assert_equal "pending", task.status
    assert_equal Date.new(2026, 6, 20), task.scheduled_date
  end

  test "「尚未吃完」給 remaining_days 視為已處理，完成任務" do
    key = "tfu_#{SecureRandom.hex(4)}"
    make_product(key, "測試戊")
    livestream = Livestream.create!(date: Date.new(2026, 6, 1), title: "t", product_keys: [key])
    cycle = build_cycle(product_key: key)
    task  = build_task(cycle, livestream)

    CrmLivestreamOutreachTaskFollowUpService.call(task: task, actor: actor, action: "not_yet_finished", remaining_days: 10)

    assert_equal "completed", task.reload.status
  end

  test "已完成任務再次操作，follow_up_event 仍會建立，但任務不會被覆寫" do
    key = "tfu_#{SecureRandom.hex(4)}"
    make_product(key, "測試己")
    livestream = Livestream.create!(date: Date.new(2026, 6, 1), title: "t", product_keys: [key])
    cycle = build_cycle(product_key: key)
    task  = build_task(cycle, livestream)
    task.complete!
    original_completed_at = task.completed_at

    travel 1.hour do
      assert_difference -> { cycle.follow_up_events.count }, 1 do
        CrmLivestreamOutreachTaskFollowUpService.call(task: task, actor: actor, action: "paused")
      end
    end

    task.reload
    assert_equal "completed", task.status
    assert_equal original_completed_at.to_i, task.completed_at.to_i
  end
end

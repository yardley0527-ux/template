# frozen_string_literal: true

# 「我的今日任務」頁面的操作入口。完全沿用 Phase 2 的
# CrmCustomerProductCycleFollowUpService（不建立第二套聯絡紀錄，
# follow_up_event 正常帶 livestream_id），只在那之後額外處理任務本身的
# 完成/日期狀態：
#
#   - 已完成任務（status == completed）不可再被覆寫，直接跳過任務更新
#     （聯絡歷史事件仍然會照常建立，只是不會動任務本身）。
#   - action == note_only：純備註，不自動完成任務、不改日期。
#   - 結果是 follow_up_status == "rescheduled"（不論是「指定日期再聯絡」
#     還是「尚未吃完」只給 next_contact_date 那個分支）：更新任務的
#     scheduled_date 為新的 next_contact_date，任務保持 pending——這樣
#     同一顧客在這場直播永遠只有一筆任務列（唯一索引本來就保證這件事），
#     且它的日期會跟著最新的約定時間走，不會留著一筆過期資訊的 pending 任務。
#   - 其他情況（已聯絡等待回覆/暫停/已回購/尚未吃完但改剩餘天數）：
#     視為這筆任務已經處理完畢，標記 completed 並記錄 completed_at。
class CrmLivestreamOutreachTaskFollowUpService
  def self.call(task:, actor:, action:, note: nil, next_contact_date: nil, remaining_days: nil)
    new(task: task, actor: actor, action: action, note: note,
        next_contact_date: next_contact_date, remaining_days: remaining_days).call
  end

  def initialize(task:, actor:, action:, note:, next_contact_date:, remaining_days:)
    @task   = task
    @actor  = actor
    @action = action.to_s
    @note   = note
    @next_contact_date = next_contact_date
    @remaining_days    = remaining_days
  end

  def call
    event = CrmCustomerProductCycleFollowUpService.call(
      cycle:               @task.cycle,
      actor:               @actor,
      action:              @action,
      note:                @note,
      next_contact_date:   @next_contact_date,
      remaining_days:      @remaining_days,
      livestream_id:       @task.livestream_id
    )

    apply_task_effect!
    event
  end

  private

  def apply_task_effect!
    return if @task.status == "completed"
    return if @action == "note_only"

    if @task.cycle.follow_up_status == "rescheduled"
      @task.update!(scheduled_date: @task.cycle.next_contact_date)
    else
      @task.complete!
    end
  end
end

# frozen_string_literal: true

# 客服在回購追蹤 Dashboard 對一個 cycle 做的一次操作。更新 cycle 上的
# 「目前狀態」快取欄位（follow_up_status/last_contacted_at/next_contact_date/
# assigned_to_user_id），同時建立一筆不可變的 CrmCustomerProductFollowUpEvent
# 歷史紀錄——cycle 只反映最新狀態，歷史永遠在事件表裡。
#
# 「尚未吃完」給 remaining_days 時，委派給既有的
# CrmCustomerProductCycleOverrideService（Phase 1 就有，這裡不重造），
# 覆寫後 follow_up_status 清回 nil，讓畫面狀態回到用新的預估用完日即時算
# （due_today/due_soon/overdue），而不是卡在一個過期的人工狀態上。
#
# 「已回購」不會寫入或竄改 next_same_product_order_number——那個欄位只由
# CrmCustomerProductCycleBuilderService（matcher）寫入。這裡只讀取 cycle
# 當下的值存進歷史事件的 detected_order_number 快照（可能是 nil），區分
# 「系統已偵測到訂單」跟「純人工確認、沒有對應訂單」，不可能偽造 order_id。
class CrmCustomerProductCycleFollowUpService
  class InvalidActionError < StandardError; end

  def self.call(cycle:, actor:, action:, note: nil, next_contact_date: nil, remaining_days: nil,
                assigned_to_user_id: nil, livestream_id: nil)
    new(
      cycle: cycle, actor: actor, action: action, note: note,
      next_contact_date: next_contact_date, remaining_days: remaining_days,
      assigned_to_user_id: assigned_to_user_id, livestream_id: livestream_id
    ).call
  end

  def initialize(cycle:, actor:, action:, note:, next_contact_date:, remaining_days:, assigned_to_user_id:, livestream_id: nil)
    @cycle                = cycle
    @actor                = actor
    @action               = action.to_s
    @note                 = note.presence
    @next_contact_date    = next_contact_date.presence
    @remaining_days       = remaining_days.presence
    @assigned_to_user_id  = assigned_to_user_id.presence
    @livestream_id        = livestream_id.presence
  end

  def call
    validate!

    event = nil

    ActiveRecord::Base.transaction do
      apply_action!
      @cycle.last_contacted_at = Time.current
      @cycle.assigned_to_user_id = @assigned_to_user_id if @assigned_to_user_id
      @cycle.save!

      event = CrmCustomerProductFollowUpEvent.create!(
        cycle:                  @cycle,
        performed_by:           @actor,
        action:                 @action,
        note:                   @note,
        next_contact_date:      @cycle.next_contact_date,
        detected_order_number:  @action == "repurchased" ? @cycle.next_same_product_order_number : nil,
        livestream_id:          @livestream_id,
        performed_at:           Time.current
      )
    end

    event
  end

  private

  def validate!
    unless CrmCustomerProductFollowUpEvent::ACTIONS.include?(@action)
      raise InvalidActionError, "unknown action: #{@action}"
    end
    raise InvalidActionError, "actor is required" if @actor.blank?
    raise InvalidActionError, "cycle is required" if @cycle.blank?

    case @action
    when "rescheduled"
      raise InvalidActionError, "next_contact_date is required for rescheduled" if @next_contact_date.blank?
    when "not_yet_finished"
      if @remaining_days.blank? && @next_contact_date.blank?
        raise InvalidActionError, "remaining_days or next_contact_date is required for not_yet_finished"
      end
    end
  end

  def apply_action!
    case @action
    when "contacted_waiting_reply", "no_response"
      @cycle.follow_up_status  = "waiting_reply"
      @cycle.next_contact_date = @next_contact_date if @next_contact_date
    when "rescheduled"
      @cycle.follow_up_status  = "rescheduled"
      @cycle.next_contact_date = @next_contact_date
    when "not_yet_finished"
      apply_not_yet_finished!
    when "not_needed", "paused"
      @cycle.follow_up_status  = "paused"
      @cycle.next_contact_date = @next_contact_date if @next_contact_date
    when "repurchased"
      @cycle.follow_up_status = "repurchased"
    when "note_only"
      @cycle.next_contact_date = @next_contact_date if @next_contact_date
    end
  end

  def apply_not_yet_finished!
    if @remaining_days
      CrmCustomerProductCycleOverrideService.call(
        cycle: @cycle, remaining_days: @remaining_days,
        source: "follow_up:#{@actor.username}"
      )
      @cycle.follow_up_status  = nil # 回到日期即時算的狀態，反映新的預估用完日
      @cycle.next_contact_date = @next_contact_date if @next_contact_date
    else
      @cycle.follow_up_status  = "rescheduled"
      @cycle.next_contact_date = @next_contact_date
    end
  end
end

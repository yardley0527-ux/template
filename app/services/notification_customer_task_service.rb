# frozen_string_literal: true

# 把「客戶商機」通知卡上勾選的客戶，寫進既有的 CrmCustomerProductCycle
# 回購追蹤系統（跟回購追蹤 Dashboard 是同一份資料、同一支寫入服務
# CrmCustomerProductCycleFollowUpService）——刻意不另開一張任務表，避免
# 兩套客服排程互不相通。
#
# 同一客戶（identity_key）＋同一產品（product_key）如果已經有未結案的
# follow_up_status（不是 nil、不是 repurchased），視為「已有未完成客服任務」，
# 跳過不重複建立。
class NotificationCustomerTaskService
  Result = Struct.new(:created, :skipped, :no_cycle, keyword_init: true)

  def self.call(notification:, emails:, actor:, assigned_to_user_id: nil, contact_date: nil)
    new(notification: notification, emails: emails, actor: actor,
        assigned_to_user_id: assigned_to_user_id, contact_date: contact_date).call
  end

  def initialize(notification:, emails:, actor:, assigned_to_user_id:, contact_date:)
    @notification = notification
    @emails = Array(emails).map(&:presence).compact.uniq
    @actor = actor
    @assigned_to_user_id = assigned_to_user_id.presence&.to_i
    @contact_date = contact_date || Date.current
  end

  def call
    created = 0
    skipped = 0
    no_cycle = 0

    @emails.each do |email|
      cycle = matching_cycle(email)
      if cycle.nil?
        no_cycle += 1
        next
      end

      if active_follow_up?(cycle)
        skipped += 1
        next
      end

      CrmCustomerProductCycleFollowUpService.call(
        cycle: cycle, actor: @actor, action: "rescheduled",
        note: "由營運提醒中心「#{@notification.title}」建立",
        next_contact_date: @contact_date, assigned_to_user_id: @assigned_to_user_id
      )
      created += 1
    end

    Result.new(created: created, skipped: skipped, no_cycle: no_cycle)
  end

  private

  # 通知卡的 metadata["query"]["product_key"] 是規則產生時存的目標產品；
  # vip_silent/high_spender_no_second 沒有單一 product_key（跨產品／首購批次），
  # 這兩類目前無法對應到單一 cycle，一律算 no_cycle（不是「已有任務」，是
  # 「這個資料模型還沒辦法對應到單一週期」，避免誤導成已處理）。
  def matching_cycle(email)
    product_key = @notification.metadata.dig("query", "product_key")
    return nil if product_key.blank?

    CrmCustomerProductCycle.where(email: email, product_key: product_key, match_status: "not_yet_repurchased")
                            .order(cycle_started_at: :desc).first
  end

  def active_follow_up?(cycle)
    cycle.follow_up_status.present? && cycle.follow_up_status != "repurchased"
  end
end

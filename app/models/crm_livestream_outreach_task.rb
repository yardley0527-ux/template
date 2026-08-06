# frozen_string_literal: true

# 一場直播、一位顧客的已確認排程任務。候選 query（LivestreamRepurchaseCandidateQuery）
# 繼續即時計算，這張表只落地保存「已經排定要做的事」，避免候選資料之後變動
# 讓每日任務內容漂移。只由 CrmLivestreamOutreachScheduler（建立）與
# CrmLivestreamOutreachTaskFollowUpService（完成/重新排程）寫入。
#
# 唯一性：(livestream_id, crm_customer_product_cycle_id) 與
# (livestream_id, identity_key) 各自唯一——後者才是真正防止「同一顧客被
# 排給不同客服」的關鍵（一個顧客同時命中多產品也只會有一筆代表 cycle 的任務）。
#
# 重新排程只能透過 CrmLivestreamOutreachScheduler#reschedule! 明確操作，
# 用 PaperTrail 記錄 scheduled_date/assigned_to_user_id 的變更歷史——不是
# delete_all 清空重建。
class CrmLivestreamOutreachTask < ApplicationRecord
  STATUSES = %w[pending completed].freeze

  has_paper_trail on: %i[update], only: %w[scheduled_date assigned_to_user_id]

  belongs_to :livestream
  belongs_to :cycle, class_name: "CrmCustomerProductCycle", foreign_key: :crm_customer_product_cycle_id
  belongs_to :assigned_to, class_name: "User", foreign_key: :assigned_to_user_id
  belongs_to :created_by, class_name: "User", foreign_key: :created_by_user_id

  validates :identity_key, presence: true
  validates :scheduled_date, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :candidate_reason, presence: true
  validates :crm_customer_product_cycle_id, uniqueness: { scope: :livestream_id }
  validates :identity_key, uniqueness: { scope: :livestream_id }

  scope :for_user, ->(user) { where(assigned_to_user_id: user.id) }
  scope :pending_tasks, -> { where(status: "pending") }
  scope :completed_tasks, -> { where(status: "completed") }
  scope :on_date, ->(date) { where(scheduled_date: date) }
  scope :overdue_as_of, ->(date) { pending_tasks.where("scheduled_date < ?", date) }
  scope :upcoming_as_of, ->(date) { pending_tasks.where("scheduled_date > ?", date) }

  def complete!
    update!(status: "completed", completed_at: Time.current)
  end
end

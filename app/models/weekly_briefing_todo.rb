# frozen_string_literal: true

# 每週檢討報告轉出的可執行待辦。AI 只負責文字化問題/建議/名單條件描述
# （target_segment 純文字＋target_query 結構化條件)——實際名單一律由
# WeeklyBriefingTodoTargetResolver 依 CRM 現有資料查詢算出，不吃 AI 生成的
# customer id（見 CLAUDE 指示「AI 不可以虛構名單」）。
#
# 同一份週報重新產生時用 dedupe_key（同一問題的穩定指紋）比對既有列——
# 已存在就更新內容、保留 status/completed_at（客服已經勾選完成的不該被
# 重新產生打回 pending）；不存在才新建。見 WeeklyBriefingService#upsert_todos!。
class WeeklyBriefingTodo < ApplicationRecord
  PRIORITIES = %w[high medium low].freeze
  STATUSES   = %w[pending done].freeze

  belongs_to :weekly_briefing, inverse_of: :todos

  validates :dedupe_key, presence: true, uniqueness: { scope: :weekly_briefing_id }
  validates :title, presence: true
  validates :priority, inclusion: { in: PRIORITIES }
  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: "pending") }
  scope :done, -> { where(status: "done") }

  def done?
    status == "done"
  end

  def mark_done!
    update!(status: "done", completed_at: Time.current)
  end

  def reopen!
    update!(status: "pending", completed_at: nil)
  end

  def resolvable?
    target_query.present? && target_query["type"].present?
  end
end

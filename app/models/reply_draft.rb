# 回覆助手的一次測試：generating → pending → approved／rejected（失敗是 failed）。
class ReplyDraft < ApplicationRecord
  STATUSES = %w[generating pending approved rejected failed].freeze

  validates :question, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }

  def direct_match?
    match_ref.present? && !needs_human
  end
end

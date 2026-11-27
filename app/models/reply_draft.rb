# 回覆助手的一次測試：generating → pending → approved／rejected（失敗是 failed）。
class ReplyDraft < ApplicationRecord
  STATUSES = %w[generating pending approved rejected failed].freeze

  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :reviewed_by, class_name: "User", optional: true

  validates :question, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }

  # 資料庫沒有相關回答，要 Chloe 親自回覆
  def no_answer?
    citations["no_answer"] == true
  end

  # 回覆裡每個重點的依據（Chloe 回答原文）
  def sources
    Array(citations["sources"])
  end

  # 知識庫裡說法跟回覆不同的回答
  def conflicts
    Array(citations["conflicts"])
  end

  def direct_match?
    match_ref.present? && !needs_human
  end
end

# 核准過的問答。status=approved 才會被回覆助手引用。
class ReplyKnowledgeItem < ApplicationRecord
  STATUSES = %w[pending approved rejected].freeze
  SOURCES = %w[chloe voice instagram].freeze

  validates :question, :answer, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }

  scope :approved, -> { where(status: "approved") }
end

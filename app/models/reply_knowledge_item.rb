# 回覆助手的知識。Chloe 的歷史回覆視為已核准；status=rejected 的不再使用。
class ReplyKnowledgeItem < ApplicationRecord
  STATUSES = %w[pending approved rejected].freeze
  SOURCES = %w[chloe voice instagram].freeze

  validates :question, :answer, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }

  scope :approved, -> { where(status: "approved") }

  def products
    ReplyAssistant::Category.products(question, answer)
  end

  def topics
    ReplyAssistant::Category.topics(question, answer)
  end
end

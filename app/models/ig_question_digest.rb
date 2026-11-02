# 某一天 IG 未回覆問題的 AI 整理（總結＋建議），每題的分類寫回 ig_questions.category。
class IgQuestionDigest < ApplicationRecord
  STATUSES = %w[pending done failed].freeze

  validates :day, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
end

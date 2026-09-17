class GroupBuyDetection < ApplicationRecord
  STATUSES = %w[待確認 已確認團購 已排除].freeze

  belongs_to :ig_post

  validates :status, inclusion: { in: STATUSES }

  before_validation { self.status = STATUSES.first if status.blank? }

  scope :ordered_for_review, -> { order(confidence: :desc) }
end

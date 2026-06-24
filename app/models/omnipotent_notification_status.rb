class OmnipotentNotificationStatus < ApplicationRecord
  STATUSES = ["未通知", "已通知", "已回覆", "暫不需要"].freeze

  validates :email, presence: true
  validates :reference_date, presence: true
  validates :status, inclusion: { in: STATUSES }
end

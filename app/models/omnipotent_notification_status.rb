class OmnipotentNotificationStatus < ApplicationRecord
  STATUSES  = ["未通知", "已通知", "已回覆", "暫不需要"].freeze
  CHANNELS  = ["IG", "LINE", "電話"].freeze
  RESULTS   = ["已讀未回", "有回覆", "已訂購", "暫不需要"].freeze

  validates :email,          presence: true
  validates :reference_date, presence: true
  validates :status,         inclusion: { in: STATUSES }
  validates :product_key,    presence: true
  validates :email,          uniqueness: { scope: [:reference_date, :product_key] }
end

# path: app/models/message_list_recipient.rb
# frozen_string_literal: true

# 名單成員：email 為正規化（LOWER/TRIM）後的識別鍵，
# 其餘欄位是建立名單當下從 shopline_customers / shopline_orders 抄來的快照。
#
# maintenance_date 起到 next_follow_up_date 這幾欄是人工維護紀錄——聯繫完
# 客人之後直接在名單上填寫，跟系統自動判斷的回購成效分開記錄。
class MessageListRecipient < ApplicationRecord
  belongs_to :message_list

  validates :email, presence: true, uniqueness: { scope: :message_list_id }

  CUSTOMER_STATUS_OPTIONS = %w[有需求 觀望中 暫時不需要 已讀未回 明確拒絕].freeze

  MAINTENANCE_CONTENT_FIELDS = {
    "content_usage_status"      => "使用狀況",
    "content_restock_reminder"  => "補貨提醒",
    "content_product_education" => "產品教育",
    "content_promotion_notice"  => "活動通知",
    "content_upgrade_reminder"  => "升等提醒"
  }.freeze
end

# path: app/models/message_list.rb
# frozen_string_literal: true

# 一批已傳送訊息的客人名單：記錄傳送日期與目標商品，
# 回購成效由 MessageListsController 讀取時即時比對 shopline_orders。
class MessageList < ApplicationRecord
  has_many :recipients, class_name: "MessageListRecipient", dependent: :destroy

  validates :name, :sent_on, :target_product, presence: true
end

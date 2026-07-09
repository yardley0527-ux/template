# path: app/models/message_list_recipient.rb
# frozen_string_literal: true

# 名單成員：email 為正規化（LOWER/TRIM）後的識別鍵，
# 其餘欄位是建立名單當下從 shopline_customers / shopline_orders 抄來的快照。
class MessageListRecipient < ApplicationRecord
  belongs_to :message_list

  validates :email, presence: true, uniqueness: { scope: :message_list_id }
end

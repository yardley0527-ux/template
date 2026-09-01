# path: app/models/message_list.rb
# frozen_string_literal: true

# 一批已傳送訊息的客人名單：記錄傳送日期與目標商品，
# 回購成效由 MessageListsController 讀取時即時比對 shopline_orders。
#
# source 分兩種，畫面上刻意分開兩個頁面顯示，不混在一起：
#   manual        — 人工湊的名單（例如回購 cohort × 買過某商品），/message_lists
#   daily_snapshot — 每天早上 ops:notifications 自動依「今日待處理」記錄，/message_lists/daily
class MessageList < ApplicationRecord
  SOURCES = %w[manual daily_snapshot].freeze

  has_many :recipients, class_name: "MessageListRecipient", dependent: :destroy

  validates :name, :sent_on, :target_product, presence: true
  validates :source, inclusion: { in: SOURCES }

  scope :manual, -> { where(source: "manual") }
  scope :daily_snapshot, -> { where(source: "daily_snapshot") }
end

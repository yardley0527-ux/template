# IG 沒有被 ManyChat 自動回覆的一則客人訊息，見 CreateIgQuestions migration 說明。
class IgQuestion < ApplicationRecord
  CATEGORIES = %w[價格／優惠活動 產品功效／適合誰 吃法／搭配 出貨／物流 訂單／付款 缺貨／到貨 合作／業配邀約 抱怨／售後 打招呼／閒聊 其他].freeze
  STATUSES = { "open" => "待處理", "handled" => "已加進自動回覆／FAQ", "ignored" => "不用處理" }.freeze

  validates :question, presence: true
  validates :status, inclusion: { in: STATUSES.keys }
  validates :category, inclusion: { in: CATEGORIES }, allow_nil: true

  # 以台灣日期算「哪一天問的」
  scope :on_day, ->(day) { where(asked_at: day.in_time_zone.all_day) }

  def status_label = STATUSES[status]
end

# frozen_string_literal: true

# 把「今日待處理」裡同一個產品底下的多張通知卡（可能同時有逾期未回購／
# 即將用完／官網優惠機會）合併成一份客人聯絡名單，同一位客人只出現一次，
# 並附上是因為哪幾張卡被列進來（同一客戶同時符合多個產品條件時的合併顯示，
# 避免客服同一天被同一件事重複提醒兩次）。
#
# 每張卡各自呼叫既有的 NotificationCustomerListService（即時 live-recheck，
# 不吃任何快取），這裡只做合併/去重，不重新設計名單邏輯本身。
class NotificationProductCustomersService
  def self.call(notifications)
    new(notifications).call
  end

  def initialize(notifications)
    @notifications = notifications
  end

  def call
    merged = {}
    @notifications.each do |notification|
      NotificationCustomerListService.call(notification).each do |row|
        key = row[:email].presence || row[:customer_id]
        next if key.blank?

        merged[key] ||= row.merge(reasons: [])
        merged[key][:reasons] << notification.title
      end
    end
    merged.values
  end
end

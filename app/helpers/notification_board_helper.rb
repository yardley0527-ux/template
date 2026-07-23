# frozen_string_literal: true

module NotificationBoardHelper
  SEVERITY_BADGE_CLASS = {
    "critical" => "badge-danger", "warning" => "badge-warning",
    "opportunity" => "badge-info", "info" => "badge-secondary"
  }.freeze

  SEVERITY_LABEL = {
    "critical" => "緊急", "warning" => "警告", "opportunity" => "機會", "info" => "提示"
  }.freeze

  CATEGORY_LABEL = {
    "system_health" => "系統健康", "inventory_attention" => "庫存", "event_attention" => "活動",
    "customer_runout" => "即將用完", "customer_overdue" => "逾期未回購",
    "high_spender_no_second" => "破萬未二購", "vip_silent" => "VIP 沉睡", "product_attention" => "產品趨勢",
    "promotion_opportunity" => "官網優惠商機"
  }.freeze

  # Categories NotificationCustomerListService knows how to expand — must stay
  # in sync with that service's `case` branches (kept as a plain literal,
  # not a cross-reference to NotificationBoardController::OPPORTUNITY_CATEGORIES,
  # since that reference forms a Zeitwerk autoload cycle: the controller loads
  # this helper via ActionController::Helpers, and this constant would in turn
  # trigger loading the controller mid-load).
  EXPANDABLE_CATEGORIES = %w[customer_runout customer_overdue high_spender_no_second vip_silent promotion_opportunity].freeze

  def notification_severity_badge_class(severity)
    SEVERITY_BADGE_CLASS.fetch(severity, "badge-secondary")
  end

  def notification_severity_label(severity)
    SEVERITY_LABEL.fetch(severity, severity)
  end

  def notification_category_label(category)
    CATEGORY_LABEL.fetch(category, category)
  end

  def notification_expandable?(notification)
    EXPANDABLE_CATEGORIES.include?(notification.category)
  end

  EMPTY_STATE_MESSAGE = {
    "today" => "今天沒有需要立即處理的緊急事項", "opportunities" => "目前沒有客戶商機提醒",
    "products" => "目前沒有產品相關提醒", "system" => "系統運作正常，沒有健康度警訊"
  }.freeze

  def notification_empty_state_message(section)
    EMPTY_STATE_MESSAGE.fetch(section, "目前沒有通知")
  end
end

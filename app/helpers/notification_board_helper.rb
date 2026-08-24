# frozen_string_literal: true

module NotificationBoardHelper
  SEVERITY_BADGE_CLASS = {
    "critical" => "badge-danger", "warning" => "badge-warning",
    "opportunity" => "badge-info", "info" => "badge-secondary"
  }.freeze

  SEVERITY_LABEL = {
    "critical" => "緊急", "warning" => "警告", "opportunity" => "機會", "info" => "提示"
  }.freeze

  PRIORITY_BADGE_CLASS = {
    "P0" => "badge-danger", "P1" => "badge-warning", "P2" => "badge-info", "P3" => "badge-light text-muted border"
  }.freeze

  PRIORITY_LABEL = {
    "P0" => "P0・立即處理", "P1" => "P1・今天處理", "P2" => "P2・本週處理", "P3" => "P3・觀察"
  }.freeze

  STATUS_BADGE_CLASS = {
    "detected" => "badge-light text-muted border", "pending_assignment" => "badge-warning",
    "in_progress" => "badge-primary", "pending_verification" => "badge-info",
    "resolved" => "badge-success", "snoozed" => "badge-secondary", "dismissed" => "badge-light text-muted border"
  }.freeze

  STATUS_LABEL = {
    "detected" => "已偵測", "pending_assignment" => "待分派", "in_progress" => "處理中",
    "pending_verification" => "待系統確認", "resolved" => "已解決", "snoozed" => "已延後", "dismissed" => "已忽略"
  }.freeze

  CATEGORY_LABEL = {
    "system_health" => "系統健康", "inventory_attention" => "庫存到貨", "event_attention" => "直播活動（已停用，見直播營運）",
    "customer_runout_p1" => "即將用完", "customer_runout_p2" => "即將用完", "customer_runout" => "即將用完",
    "customer_overdue" => "逾期未回購",
    "high_spender_no_second" => "破萬未二購", "vip_silent" => "VIP 沉睡", "product_attention" => "商品營收",
    "promotion_opportunity" => "官網優惠商機",
    "livestream_schedule_gap" => "直播週期缺口", "livestream_preparation" => "直播前準備",
    "livestream_day_attention" => "直播當天摘要", "livestream_performance_drop" => "直播後表現比較",
    "livestream_review_due" => "直播檢討待完成"
  }.freeze

  BROAD_CATEGORY_LABEL = {
    "customer_opportunity" => "客戶商機", "product_revenue" => "商品營收", "inventory" => "庫存到貨",
    "livestream_event" => "直播營運", "system_health" => "系統健康"
  }.freeze

  DISMISSAL_REASON_LABEL = {
    "misjudged" => "誤判", "not_applicable" => "不適用", "known_risk" => "已知風險", "permanently_excluded" => "永久排除"
  }.freeze

  # Categories NotificationCustomerListService knows how to expand — must stay
  # in sync with that service's `case` branches (kept as a plain literal,
  # not a cross-reference to NotificationBoardController::SECTION_CATEGORIES,
  # since that reference forms a Zeitwerk autoload cycle: the controller loads
  # this helper via ActionController::Helpers, and this constant would in turn
  # trigger loading the controller mid-load).
  EXPANDABLE_CATEGORIES = %w[customer_runout customer_runout_p1 customer_runout_p2 customer_overdue
                             high_spender_no_second vip_silent promotion_opportunity].freeze

  def notification_severity_badge_class(severity)
    SEVERITY_BADGE_CLASS.fetch(severity, "badge-secondary")
  end

  def notification_severity_label(severity)
    SEVERITY_LABEL.fetch(severity, severity)
  end

  def notification_priority_badge_class(priority)
    PRIORITY_BADGE_CLASS.fetch(priority, "badge-secondary")
  end

  def notification_priority_label(priority)
    PRIORITY_LABEL.fetch(priority, priority)
  end

  def notification_status_badge_class(status)
    STATUS_BADGE_CLASS.fetch(status, "badge-secondary")
  end

  def notification_status_label(status)
    STATUS_LABEL.fetch(status, status)
  end

  def notification_category_label(category)
    CATEGORY_LABEL.fetch(category, category)
  end

  def notification_broad_category_label(broad_category)
    BROAD_CATEGORY_LABEL.fetch(broad_category, broad_category)
  end

  def notification_dismissal_reason_label(reason)
    DISMISSAL_REASON_LABEL.fetch(reason, reason)
  end

  def notification_expandable?(notification)
    EXPANDABLE_CATEGORIES.include?(notification.category)
  end

  EMPTY_STATE_MESSAGE = {
    "today" => "今天沒有需要處理的事項", "customer_opportunity" => "目前沒有客戶商機提醒",
    "product_revenue" => "目前沒有商品營收提醒", "inventory" => "目前沒有庫存到貨提醒",
    "livestream_event" => "目前沒有直播營運提醒", "system_health" => "系統運作正常，沒有健康度警訊"
  }.freeze

  def notification_empty_state_message(section)
    EMPTY_STATE_MESSAGE.fetch(section, "目前沒有通知")
  end
end

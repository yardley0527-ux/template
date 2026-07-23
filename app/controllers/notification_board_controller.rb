# frozen_string_literal: true

# 營運提醒中心 (Operations Alert Center). Reads from the notifications table
# only — this controller never generates notifications; that is exclusively
# NotificationEngine's job, run via `bundle exec rake ops:notifications`.
class NotificationBoardController < ApplicationController
  SECTIONS = %w[today opportunities products system completed].freeze
  TODAY_LIMIT = 8
  OPPORTUNITY_CATEGORIES = %w[customer_runout customer_overdue high_spender_no_second vip_silent promotion_opportunity].freeze
  PRODUCT_CATEGORIES = %w[inventory_attention product_attention].freeze
  COMPLETED_PER_PAGE = 20
  SEVERITY_RANK = { "critical" => 0, "warning" => 1, "opportunity" => 2, "info" => 3 }.freeze

  def index
    @section = SECTIONS.include?(params[:section]) ? params[:section] : "today"
    @unread_count = Notification.unread.count
    @tab_counts = {
      "today" => todays_attention_scope.count,
      "opportunities" => Notification.open_status.by_category(OPPORTUNITY_CATEGORIES).count,
      "products" => Notification.open_status.by_category(PRODUCT_CATEGORIES).count,
      "system" => Notification.open_status.by_category("system_health").count
    }

    case @section
    when "today"
      @notifications = todays_attention
    when "opportunities"
      @notifications = Notification.open_status.by_category(OPPORTUNITY_CATEGORIES).recent_first
    when "products"
      @notifications = Notification.open_status.by_category(PRODUCT_CATEGORIES).recent_first
    when "system"
      @notifications = Notification.open_status.by_category("system_health").recent_first
      @system_status = system_status_lights
    when "completed"
      @page = [params[:page].to_i, 1].max
      scope = Notification.where(status: %w[resolved dismissed]).order(updated_at: :desc)
      @total = scope.count
      @total_pages = [(@total.to_f / COMPLETED_PER_PAGE).ceil, 1].max
      @notifications = scope.offset((@page - 1) * COMPLETED_PER_PAGE).limit(COMPLETED_PER_PAGE)
    end
  end

  def mark_read
    notification.mark_read!
    redirect_to notification_board_path(section: params[:section]), notice: "已標示為已讀"
  end

  def resolve
    notification.resolve!
    redirect_to notification_board_path(section: params[:section]), notice: "已標示為已處理"
  end

  def dismiss
    notification.dismiss!
    redirect_to notification_board_path(section: params[:section]), notice: "已忽略"
  end

  def customers
    @notification = notification
    @rows = NotificationCustomerListService.call(@notification)
    render layout: false
  end

  private

  def notification
    @notification ||= Notification.find(params[:id])
  end

  # "今日注意" = critical 嚴重度 + 今天才首次偵測到（涵蓋 T-1 倒數、當天發生的
  # 庫存衝突等）——不是全部 open 通知，只挑「今天真的該處理」的。
  def todays_attention_scope
    Notification.open_status.where(
      "severity = ? OR first_detected_at >= ?", "critical", Date.current.beginning_of_day
    )
  end

  def todays_attention
    todays_attention_scope.to_a
      .sort_by { |n| [SEVERITY_RANK.fetch(n.severity, 9), -n.last_detected_at.to_i] }
      .first(TODAY_LIMIT)
  end

  def system_status_lights
    {
      imports: NotificationRules::SystemHealth::IMPORT_KINDS.map do |kind, label|
        { label: label, last_finished_at: ImportRun.where(kind: kind).maximum(:finished_at) }
      end,
      rollup_last_finished_at: SyncRun.last_finished_at("crm_rollup"),
      sync_sources: SyncRun::SOURCES.filter_map do |source, label|
        next if source == "crm_rollup"

        run = SyncRun.latest_for(source)
        { label: label, status: run&.status, finished_at: run&.finished_at }
      end
    }
  end
end

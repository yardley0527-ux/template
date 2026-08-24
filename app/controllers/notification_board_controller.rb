# frozen_string_literal: true

# 營運提醒中心 (Operations Alert Center). Reads from the notifications table
# only — this controller never generates notifications; that is exclusively
# NotificationEngine's job, run via `bundle exec rake ops:notifications`.
# Workflow actions (assign/start/verify/snooze/dismiss/customer task) below
# drive the state machine defined on Notification — see that model for the
# full status lifecycle.
class NotificationBoardController < ApplicationController
  SECTIONS = %w[today customer_opportunity product_revenue inventory livestream_event system_health completed].freeze
  TODAY_LIMIT = 30
  SECTION_CATEGORIES = {
    "customer_opportunity" => %w[customer_runout customer_overdue high_spender_no_second vip_silent promotion_opportunity],
    "product_revenue"      => %w[product_attention],
    "inventory"            => %w[inventory_attention],
    "livestream_event"     => %w[livestream_schedule_gap livestream_preparation livestream_day_attention
                                  livestream_performance_drop livestream_review_due],
    "system_health"        => %w[system_health]
  }.freeze
  COMPLETED_PER_PAGE = 20
  # 這三類卡片的 metadata 有單一 product_key，可以合併成「依產品列出待聯絡客人」——
  # vip_silent/high_spender_no_second 沒有單一產品可對應（跨產品沉睡／首購批次），
  # 留在「其他待處理」用原本的卡片形式顯示。
  PRODUCT_GROUPABLE_CATEGORIES = %w[customer_runout customer_overdue promotion_opportunity].freeze

  before_action :wake_expired_snoozes!, only: %i[index product_customers]

  def index
    @section = SECTIONS.include?(params[:section]) ? params[:section] : "today"
    @unread_count = Notification.unread.count
    @tab_counts = SECTION_CATEGORIES.transform_values { |cats| Notification.active.by_category(cats).count }
    @tab_counts["today"] = todays_todo_scope.count

    case @section
    when "today"
      @product_groups, @other_notifications = grouped_today_list
    when "completed"
      @page = [params[:page].to_i, 1].max
      scope = Notification.where(status: %w[resolved dismissed]).order(updated_at: :desc)
      @total = scope.count
      @total_pages = [(@total.to_f / COMPLETED_PER_PAGE).ceil, 1].max
      @notifications = scope.offset((@page - 1) * COMPLETED_PER_PAGE).limit(COMPLETED_PER_PAGE)
    else
      @notifications = Notification.active.by_category(SECTION_CATEGORIES.fetch(@section)).includes(:owner).recent_first
      @system_status = system_status_lights if @section == "system_health"
    end

    @summary = board_summary
  end

  def mark_read
    notification.mark_read!
    redirect_to notification_board_path(section: params[:section]), notice: "已標示為已讀（尚未結案）"
  end

  # 分派負責人（可同時設定期限）。
  def assign
    user = User.find(params[:owner_user_id])
    due_at = parse_datetime(params[:due_at])
    notification.assign!(user, due_at: due_at)
    redirect_to notification_board_path(section: params[:section]), notice: "已分派給 #{user.username}"
  end

  # 自己認領（不指定別人，直接開始處理）。
  def start
    notification.start!(current_user)
    redirect_to notification_board_path(section: params[:section]), notice: "已標示為處理中"
  end

  # 「已處理」— 監控型提醒統一先進 pending_verification，下一輪引擎確認條件
  # 真的不存在了才會自動變成 resolved（見 Notification#auto_resolve!）。
  def request_verification
    reason = params[:resolution_reason].presence
    unless reason
      redirect_to notification_board_path(section: params[:section]), alert: "請填寫處理說明才能送出確認"
      return
    end
    notification.request_verification!(actor: current_user, resolution_reason: reason)
    redirect_to notification_board_path(section: params[:section]), notice: "已標示處理完成，等待系統下一輪確認條件是否解除"
  end

  def snooze
    until_at = parse_date(params[:snoozed_until])
    reason = params[:snooze_reason].presence
    if until_at.nil? || reason.nil?
      redirect_to notification_board_path(section: params[:section]), alert: "延後必須填寫恢復日期與原因"
      return
    end
    notification.snooze!(until_at: until_at.end_of_day, reason: reason)
    redirect_to notification_board_path(section: params[:section]), notice: "已延後到 #{until_at}"
  end

  def dismiss
    reason = params[:dismissal_reason].presence
    unless reason && Notification::DISMISSAL_REASONS.include?(reason)
      redirect_to notification_board_path(section: params[:section]), alert: "忽略必須選擇原因"
      return
    end

    begin
      notification.dismiss!(reason: reason, actor: current_user)
      redirect_to notification_board_path(section: params[:section]), notice: "已忽略"
    rescue ArgumentError => e
      redirect_to notification_board_path(section: params[:section]), alert: e.message
    end
  end

  def customers
    @notification = notification
    @rows = NotificationCustomerListService.call(@notification)
    render layout: false
  end

  # 「今日待處理」依產品分組後，某個產品底下（可能好幾張卡）合併起來的聯絡名單。
  # 重新從 today scope 現查一次符合這個 product_key 的卡，不是憑前端傳來的
  # notification id 清單湊，避免過期資料。
  def product_customers
    @product_key = params[:product_key].to_s
    @label = JourneyProducts::PRODUCTS.dig(@product_key, :label) || @product_key
    @notifications = todays_product_notifications(@product_key)
    @rows = NotificationProductCustomersService.call(@notifications)
    render layout: false
  end

  # 客戶商機卡片的「建立客服任務」——把勾選的客戶寫進既有的
  # CrmCustomerProductCycle 回購追蹤系統（跟回購追蹤 Dashboard 是同一套資料），
  # 不是另開一個互不相通的任務表。同一客戶同一產品已有未完成任務就跳過，
  # 回報建立/跳過各幾筆。
  def create_customer_task
    n = notification
    result = NotificationCustomerTaskService.call(
      product_key: n.metadata.dig("query", "product_key"), emails: Array(params[:emails]), actor: current_user,
      note: "由營運提醒中心「#{n.title}」建立",
      assigned_to_user_id: params[:assignee_id].presence, contact_date: parse_date(params[:contact_date])
    )
    redirect_to notification_board_path(section: params[:section]), notice: customer_task_notice(result)
  end

  # 「今日待處理」依產品合併後的名單版本——不綁單一通知卡，用 product_key
  # 直接建任務（同一產品底下可能好幾張卡一起勾選聯絡名單）。
  def create_product_customer_task
    product_key = params[:product_key]
    result = NotificationCustomerTaskService.call(
      product_key: product_key, emails: Array(params[:emails]), actor: current_user,
      note: "由營運提醒中心「今日待處理・#{JourneyProducts::PRODUCTS.dig(product_key, :label) || product_key}」建立",
      assigned_to_user_id: params[:assignee_id].presence, contact_date: parse_date(params[:contact_date])
    )
    redirect_to notification_board_path(section: "today"), notice: customer_task_notice(result)
  end

  private

  def notification
    @notification ||= Notification.find(params[:id])
  end

  def customer_task_notice(result)
    "已建立 #{result[:created]} 筆客服任務" \
      "#{result[:skipped].positive? ? "，#{result[:skipped]} 位已有未完成任務跳過" : ""}" \
      "#{result[:no_cycle].positive? ? "，#{result[:no_cycle]} 位找不到對應追蹤資料" : ""}"
  end

  def wake_expired_snoozes!
    @woken_ids = Notification.snooze_expired.pluck(:id)
    Notification.wake_expired_snoozes!
  end

  # 「今日待處理」＝依 due_at／status／snoozed_until 判斷，不是「今天才第一次
  # 偵測到」。涵蓋：今天新發生的P0/P1、到期或已逾期、待分派、待系統驗證的高
  # 優先事項、延後到今天重新出現的事項。
  def todays_todo_scope
    today_start = Date.current.beginning_of_day
    tomorrow_start = Date.current.tomorrow.beginning_of_day
    woken = @woken_ids.presence || [0]

    Notification.active.where(
      "(priority IN ('P0','P1') AND first_detected_at >= :today_start) " \
      "OR (due_at IS NOT NULL AND due_at < :tomorrow_start) " \
      "OR status = 'pending_assignment' " \
      "OR (status = 'pending_verification' AND priority IN ('P0','P1')) " \
      "OR id IN (:woken)",
      today_start: today_start, tomorrow_start: tomorrow_start, woken: woken
    )
  end

  def todays_todo_list
    todays_todo_scope.includes(:owner).to_a.sort_by do |n|
      [Notification::PRIORITY_RANK.fetch(n.priority, 9), n.overdue? ? 0 : 1, -n.last_detected_at.to_i]
    end.first(TODAY_LIMIT)
  end

  # 「先看現在有哪些產品，再依產品列出要聯絡的客人」——把今日待處理清單拆成
  # 「可歸屬單一產品」跟「不能歸屬單一產品」兩堆，前者依 product_key 合併成
  # 一個產品一組（可能好幾張卡疊在一起），後者維持原本一張卡一張卡顯示。
  def grouped_today_list
    list = todays_todo_list
    groupable, other = list.partition { |n| PRODUCT_GROUPABLE_CATEGORIES.include?(n.category) && n.metadata["product_key"].present? }

    groups = groupable.group_by { |n| n.metadata["product_key"] }.map do |key, notifs|
      {
        product_key: key,
        label: JourneyProducts::PRODUCTS.dig(key, :label) || key,
        icon: JourneyProducts::PRODUCTS.dig(key, :icon),
        notifications: notifs,
        total_count: notifs.sum { |n| (n.metadata["count"] || n.metadata["total_count"] || 0).to_i },
        min_priority: notifs.min_by { |n| Notification::PRIORITY_RANK.fetch(n.priority, 9) }.priority
      }
    end.sort_by { |g| Notification::PRIORITY_RANK.fetch(g[:min_priority], 9) }

    [groups, other]
  end

  # product_customers action 用：重新現查（不吃前端傳來的清單），確保跟畫面上
  # 當下顯示的「今日待處理」內容一致。
  def todays_product_notifications(product_key)
    todays_todo_scope.where(category: PRODUCT_GROUPABLE_CATEGORIES).select do |n|
      n.metadata["product_key"] == product_key
    end
  end

  def board_summary
    active = Notification.active
    {
      today_todo: @tab_counts["today"],
      overdue: active.overdue.count,
      pending_assignment: active.where(status: "pending_assignment").count,
      in_progress: active.where(status: "in_progress").count,
      pending_verification: active.awaiting_verification.count,
      resolved_today: Notification.resolved_today.count,
      affected_customers: estimate_affected_customers(active),
      estimated_opportunity_revenue: estimate_opportunity_revenue(active)
    }
  end

  # metadata 裡各規則存的客戶人數欄位名稱不完全一致（count/total_count），
  # 逐一嘗試取值——這是「可以從已知欄位估算」的最佳努力值，不是精確去重後
  # 的真實客戶數（同一人可能同時出現在多張卡上，故標示為「估計」）。
  def estimate_affected_customers(scope)
    scope.by_category(SECTION_CATEGORIES.fetch("customer_opportunity"))
         .sum { |n| (n.metadata["count"] || n.metadata["total_count"] || 0).to_i }
  end

  # 同樣道理：只加總 metadata 裡明確代表「營收/金額」的欄位
  # （first_amount_sum／history_amount 等），沒有這類欄位的規則就不計入，
  # 不能拿「客戶數×假設單價」這種編造方式湊數字。
  def estimate_opportunity_revenue(scope)
    scope.by_category(SECTION_CATEGORIES.fetch("customer_opportunity"))
         .sum { |n| (n.metadata["first_amount_sum"] || 0).to_i }
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

  def parse_date(value)
    Date.parse(value) if value.present?
  rescue ArgumentError
    nil
  end

  def parse_datetime(value)
    Time.zone.parse(value) if value.present?
  rescue ArgumentError
    nil
  end
end

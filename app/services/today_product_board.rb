# path: app/services/today_product_board.rb
# frozen_string_literal: true

# 「今日待處理」依產品分組的共用邏輯：NotificationBoardController（畫面顯示）
# 跟 DailyMessageListSnapshotService（每天自動記錄訊息名單快照）都要算出同一份
# 「今天有哪些產品、每個產品底下要聯絡哪些客人」，抽出來避免兩邊各自兜一份、
# 兜出不一致結果的邏輯。
class TodayProductBoard
  TODAY_LIMIT = 30
  # 這三類卡片的 metadata 有單一 product_key，可以合併成「依產品列出待聯絡客人」——
  # vip_silent/high_spender_no_second 沒有單一產品可對應（跨產品沉睡／首購批次），
  # 不在此列，畫面上仍以原本卡片形式顯示。
  GROUPABLE_CATEGORIES = %w[customer_runout customer_overdue promotion_opportunity].freeze

  # 「今日待處理」＝依 due_at／status／snoozed_until 判斷，不是「今天才第一次
  # 偵測到」。涵蓋：今天新發生的P0/P1、到期或已逾期、待分派、待系統驗證的高
  # 優先事項、延後到今天重新出現的事項。
  def self.todo_scope(woken_ids: [])
    today_start = Date.current.beginning_of_day
    tomorrow_start = Date.current.tomorrow.beginning_of_day
    woken = woken_ids.presence || [0]

    Notification.active.where(
      "(priority IN ('P0','P1') AND first_detected_at >= :today_start) " \
      "OR (due_at IS NOT NULL AND due_at < :tomorrow_start) " \
      "OR status = 'pending_assignment' " \
      "OR (status = 'pending_verification' AND priority IN ('P0','P1')) " \
      "OR id IN (:woken)",
      today_start: today_start, tomorrow_start: tomorrow_start, woken: woken
    )
  end

  # 畫面用：把今日待處理清單拆成「可歸屬單一產品」跟「不能歸屬單一產品」兩堆，
  # 前者依 product_key 合併成一個產品一組（可能好幾張卡疊在一起）。
  def self.groups(woken_ids: [])
    list = todo_scope(woken_ids: woken_ids).includes(:owner).to_a.sort_by do |n|
      [Notification::PRIORITY_RANK.fetch(n.priority, 9), n.overdue? ? 0 : 1, -n.last_detected_at.to_i]
    end.first(TODAY_LIMIT)

    groupable, other = list.partition { |n| GROUPABLE_CATEGORIES.include?(n.category) && n.metadata["product_key"].present? }

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

  # 某個產品底下（可能好幾張卡）合併起來的聯絡名單用：不吃 groups 的 TODAY_LIMIT，
  # 現查一次符合這個 product_key 的全部卡，避免漏人。
  def self.for_product(product_key, woken_ids: [])
    todo_scope(woken_ids: woken_ids).where(category: GROUPABLE_CATEGORIES).select do |n|
      n.metadata["product_key"] == product_key
    end
  end
end

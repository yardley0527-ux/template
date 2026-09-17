# frozen_string_literal: true

# 升級名單：彙整 DailyUpgradeMessageListService 每次會員報表匯入後自動記錄的
# 「升級為白卡/銀卡/金卡/黑卡」名單快照，讓營運可以直接在會員管理選單裡看到，
# 不用跟每日商品回購名單混在一起找。實際的名單內容／匯出沿用既有的
# MessageList show／export 頁面，這裡只做彙整與篩選。
class UpgradedMembersController < ApplicationController
  TARGET_LEVELS = %w[白卡 銀卡 金卡 黑卡].freeze

  # 本週／本月／本年都是「該期間至今」（例如本月＝這個月 1 號到今天），
  # 不是固定往前推 7/30/365 天，符合一般講「本週升了幾個」的直覺。
  PERIODS = {
    "今天" => ->(today) { today..today },
    "本週" => ->(today) { today.beginning_of_week..today },
    "本月" => ->(today) { today.beginning_of_month..today },
    "本年" => ->(today) { today.beginning_of_year..today }
  }.freeze

  def index
    @selected_level = TARGET_LEVELS.include?(params[:level].to_s) ? params[:level].to_s : nil

    all_lists = MessageList.daily_snapshot.where(target_product: TARGET_LEVELS).to_a
    @period_counts = build_period_counts(all_lists)
    @maintenance_period_counts = build_maintenance_period_counts(all_lists)
    @period_range_labels = build_period_range_labels

    @content_window = PERIODS.key?(params[:content_window].to_s) ? params[:content_window].to_s : "本月"
    @content_stats = build_content_stats(@content_window)

    # 第一層：月份分頁（"2026-09" 這種 key，畫面上顯示成「2026年9月」）。
    @available_months = all_lists.map { |l| l.sent_on.strftime("%Y-%m") }.uniq.sort.reverse
    @selected_month = @available_months.include?(params[:month].to_s) ? params[:month].to_s : @available_months.first
    lists_in_month = all_lists.select { |l| l.sent_on.strftime("%Y-%m") == @selected_month }

    # 第二層：日期分頁——同一天最多就 4 張卡別的名單，不用再往下列成一長串。
    @available_days = lists_in_month.map(&:sent_on).uniq.sort.reverse
    @selected_day = @available_days.find { |d| d.iso8601 == params[:day].to_s } || @available_days.first
    lists_on_day = lists_in_month.select { |l| l.sent_on == @selected_day }

    # 第三層：卡別篩選（選填）——同一天本來就只有 4 張，篩選只是輔助，不是必要。
    scope = @selected_level ? lists_on_day.select { |l| l.target_product == @selected_level } : lists_on_day
    @lists = scope.sort_by { |l| TARGET_LEVELS.index(l.target_product).to_i }
    @recipient_counts = MessageListRecipient.where(message_list_id: @lists.map(&:id)).group(:message_list_id).count
  end

  private

  # 表頭旁邊要顯示「本週/本月/本年」實際對應到哪個區間，不然使用者猜不到基準日。
  # { "今天" => "9/17", "本週" => "9/15~9/17", "本月" => "9/1~9/17", "本年" => "1/1~9/17" }
  def build_period_range_labels
    today = Date.current
    PERIODS.each_with_object({}) do |(label, range_for), out|
      range = range_for.call(today)
      out[label] = range.first == range.last ? range.first.strftime("%-m/%-d") : "#{range.first.strftime('%-m/%-d')}~#{range.last.strftime('%-m/%-d')}"
    end
  end

  # { "今天" => { "白卡" => 3, "銀卡" => 0, ... }, "本週" => {...}, ... }
  def build_period_counts(lists)
    today = Date.current
    lists_by_level = lists.group_by(&:target_product)

    PERIODS.each_with_object({}) do |(label, range_for), out|
      range = range_for.call(today)
      out[label] = TARGET_LEVELS.index_with do |level|
        ids = (lists_by_level[level] || []).select { |l| range.cover?(l.sent_on) }.map(&:id)
        ids.empty? ? 0 : MessageListRecipient.where(message_list_id: ids).count
      end
    end
  end

  # 跟 build_period_counts 不同：這裡看的是「維護日期」（本次維護什麼時候填的），
  # 不是名單傳送日，所以同一批名單裡的人可能分散在不同期間才被算到已維護。
  def build_maintenance_period_counts(lists)
    today = Date.current
    lists_by_level = lists.group_by(&:target_product)

    PERIODS.each_with_object({}) do |(label, range_for), out|
      range = range_for.call(today)
      out[label] = TARGET_LEVELS.index_with do |level|
        ids = (lists_by_level[level] || []).map(&:id)
        ids.empty? ? 0 : MessageListRecipient.where(message_list_id: ids, maintenance_date: range).count
      end
    end
  end

  # 「員工什麼時候維護、維護後有沒有回來買」——依維護日期落在哪個 window（今天/本週/本月/本年，
  # 累計到今天）篩出那批人，再拆成 5 個維護內容勾選項各自的回購率。回購定義：維護日期之後
  # 有任何一筆已付款訂單（不限定商品，因為升級名單本來就不是針對單一商品）。
  # 同一人可能同時勾多個項目，所以 by_field 的人數各自獨立、加總會超過 total。
  def build_content_stats(window_label)
    range = PERIODS.fetch(window_label).call(Date.current)
    rows = maintenance_rows_with_repurchase.select { |r| range.cover?(r["maintenance_date"].to_date) }

    by_field = MessageListRecipient::MAINTENANCE_CONTENT_FIELDS.map do |field, label|
      marked = rows.select { |r| r[field] }
      repurchased = marked.count { |r| r["repurchased"] }
      rate = marked.empty? ? 0.0 : (repurchased * 100.0 / marked.size)
      { field: field, label: label, total: marked.size, repurchased: repurchased, rate: rate }
    end.sort_by { |h| -h[:rate] }

    total = rows.size
    repurchased_total = rows.count { |r| r["repurchased"] }
    rate_total = total.zero? ? 0.0 : (repurchased_total * 100.0 / total)

    { total: total, repurchased: repurchased_total, rate: rate_total, by_field: by_field }
  end

  # 只查一次，5 個 window 共用（比對日期用 Ruby 篩，不必為每個 window 各查一次 DB）。
  def maintenance_rows_with_repurchase
    content_columns = MessageListRecipient::MAINTENANCE_CONTENT_FIELDS.keys.join(", ")

    sql = <<~SQL
      SELECT r.email, r.maintenance_date, #{content_columns},
             EXISTS (
               SELECT 1 FROM shopline_orders o
               WHERE LOWER(TRIM(o.email)) = r.email
                 AND o.payment_status = '已付款'
                 AND o.order_date >= r.maintenance_date
             ) AS repurchased
      FROM message_list_recipients r
      JOIN message_lists ml ON ml.id = r.message_list_id
      WHERE ml.source = 'daily_snapshot' AND ml.name LIKE '%升級%名單'
        AND r.maintenance_date IS NOT NULL
    SQL

    ActiveRecord::Base.connection.select_all(sql).to_a
  end
end

# path: app/controllers/message_lists_controller.rb
# frozen_string_literal: true

# 訊息名單追蹤：每批名單記錄傳送日期與目標商品，
# 回購成效即時比對 shopline_orders（傳送日起、已付款、含目標商品的訂單才算）。
class MessageListsController < ApplicationController
  MEMBERSHIP_RANK = { "黑卡" => 1, "金卡" => 2, "銀卡" => 3, "白卡" => 4, "一般會員" => 5 }.freeze

  # 人工湊的名單（例如回購 cohort × 買過某商品）——跟每天自動記錄的
  # 「今日待處理」快照分開顯示，見 #daily。
  def index
    @lists = MessageList.manual.order(sent_on: :desc, id: :desc).to_a
    @recipient_counts = MessageListRecipient.group(:message_list_id).count
    @stats = @lists.to_h { |list| [list.id, build_stats(list, repurchases_for(list))] }
  end

  # 每天早上 ops:notifications 自動依「今日待處理」記錄的名單快照，
  # 上面加一個依產品彙總的本週回購成效，跟人工名單（#index）分開顯示。
  def daily
    @lists = MessageList.daily_snapshot.order(sent_on: :desc, id: :desc).to_a
    @recipient_counts = MessageListRecipient.group(:message_list_id).count
    @stats = @lists.to_h { |list| [list.id, build_stats(list, repurchases_for(list))] }

    @week_range = (Date.current - 6)..Date.current
    @weekly_summary = weekly_summary(@lists, @week_range)
  end

  def show
    @list = MessageList.find(params[:id])
    @tab = %w[repurchased pending].include?(params[:tab]) ? params[:tab] : "repurchased"

    @repurchases = repurchases_for(@list)
    @stats = build_stats(@list, @repurchases)

    recipients = sorted_recipients(@list)
    @repurchased_rows, @pending_rows = recipients.partition { |r| @repurchases.key?(r.email) }
    @rows = @tab == "repurchased" ? @repurchased_rows : @pending_rows

    @segment_rows = segment_stats(recipients, @repurchases)
    @curve = repurchase_curve(@list, recipients, @repurchases, top_segments: @segment_rows.map { |r| r[:segment] } - ["其他"])
  end

  def update
    list = MessageList.find(params[:id])
    list.update!(params.require(:message_list).permit(:message_content))
    redirect_to message_list_path(list), notice: "訊息內容已儲存"
  end

  def export
    list = MessageList.find(params[:id])
    repurchases = repurchases_for(list)

    require "csv"

    csv = CSV.generate(encoding: "UTF-8") do |rows|
      rows << ["姓名", "IG", "Email", "會員等級", "分類", "回購狀態", "回購日期", "回購商品", "回購金額"]
      sorted_recipients(list).each do |r|
        rep = repurchases[r.email]
        rows << [
          r.full_name,
          r.instagram_account,
          r.email,
          r.membership_level,
          r.segment,
          rep ? "已回購" : "未回購",
          rep && rep["order_date"].to_date,
          rep && rep["product_names"],
          rep && rep["order_total"].to_i
        ]
      end
    end

    send_data "\xEF\xBB\xBF" + csv,
              filename: "#{list.name}_#{list.sent_on}.csv",
              type: "text/csv; charset=utf-8"
  end

  private

  # 近 7 天（含週末，但平日 cron 才會產生名單）依目標商品彙總——「這個產品這週
  # 傳了幾天、共幾人、回購幾人」，讓使用者一進頁面就看到最近成效，不用逐批點進去看。
  def weekly_summary(lists, range)
    lists.select { |l| range.cover?(l.sent_on) }
         .group_by(&:target_product)
         .map do |product, group|
      stats = group.map { |l| @stats[l.id] }
      total = stats.sum { |s| s[:total] }
      repurchased = stats.sum { |s| s[:repurchased] }
      {
        product: product,
        days: group.size,
        total: total,
        repurchased: repurchased,
        rate: total.positive? ? (repurchased * 100.0 / total).round(1) : nil,
        revenue: stats.sum { |s| s[:revenue] }
      }
    end.sort_by { |h| -h[:total] }
  end

  def sorted_recipients(list)
    list.recipients.sort_by { |r| [MEMBERSHIP_RANK.fetch(r.membership_level, 6), r.full_name.to_s] }
  end

  # 每位名單成員在傳送日（含當天）之後，最早一張含目標商品的已付款訂單。
  # 目標商品可用「、」或「,」分隔多個關鍵字，符合任一個即算。
  # 金額為整張訂單總額（同破8000追蹤成效的口徑：MAX total_amount，缺失才 SUM checkout_amount）。
  def repurchases_for(list)
    product_match = list.target_product.split(/[、,]/).filter_map { |k| k.strip.presence }
                        .map { |k| "o.product_name ILIKE #{connection.quote("%#{k}%")}" }
                        .join(" OR ")

    sql = <<~SQL
      WITH hits AS (
        SELECT r.email AS email_key,
               o.order_number,
               MIN(o.order_date) AS order_date,
               STRING_AGG(DISTINCT o.product_name, ' / ') AS product_names
        FROM shopline_orders o
        JOIN message_list_recipients r
          ON r.message_list_id = #{list.id.to_i}
         AND LOWER(TRIM(o.email)) = r.email
        WHERE o.payment_status = '已付款'
          AND o.order_number IS NOT NULL AND o.order_number <> ''
          AND o.order_date >= #{connection.quote(list.sent_on)}
          AND (#{product_match})
        GROUP BY r.email, o.order_number
      ),
      first_hit AS (
        SELECT DISTINCT ON (email_key) email_key, order_number, order_date, product_names
        FROM hits
        ORDER BY email_key, order_date ASC
      ),
      totals AS (
        SELECT order_number, #{ShoplineOrder::TOTAL_SQL} AS order_total
        FROM shopline_orders
        WHERE payment_status = '已付款'
          AND order_number IN (SELECT order_number FROM first_hit)
        GROUP BY order_number
      )
      SELECT f.email_key, f.order_number, f.order_date, f.product_names, t.order_total
      FROM first_hit f
      JOIN totals t ON t.order_number = f.order_number
    SQL

    connection.select_all(sql).to_a.index_by { |r| r["email_key"] }
  end

  # 各分類的人數／回購數／回購率／帶回營業額；沒設定分類的歸「未分類」。
  # 只顯示人數前 SEGMENT_TOP_N 名的分類，其餘合併成「其他」，避免長尾（1~2人）分類洗版。
  SEGMENT_TOP_N = 5

  def segment_stats(recipients, repurchases)
    rows = recipients.group_by { |r| r.segment.presence || "未分類" }.map do |segment, group|
      reps = group.filter_map { |r| repurchases[r.email] }
      {
        segment: segment,
        total: group.size,
        repurchased: reps.size,
        rate: (reps.size * 100.0 / group.size).round(1),
        revenue: reps.sum { |r| r["order_total"].to_i }
      }
    end.sort_by { |h| -h[:total] }

    return rows if rows.size <= SEGMENT_TOP_N

    top, rest = rows.first(SEGMENT_TOP_N), rows.drop(SEGMENT_TOP_N)
    other_total = rest.sum { |h| h[:total] }
    other_repurchased = rest.sum { |h| h[:repurchased] }
    top + [{
      segment: "其他",
      total: other_total,
      repurchased: other_repurchased,
      rate: other_total.zero? ? 0.0 : (other_repurchased * 100.0 / other_total).round(1),
      revenue: rest.sum { |h| h[:revenue] }
    }]
  end

  # 傳送後累積回購曲線（依分類分series）：x=傳送後第N天、y=累積回購人數。
  # top_segments 之外的分類併入「其他」，跟 segment_stats 的長尾合併規則一致。
  def repurchase_curve(list, recipients, repurchases, top_segments:)
    segment_by_email = recipients.to_h do |r|
      raw = r.segment.presence || "未分類"
      [r.email, top_segments.include?(raw) ? raw : "其他"]
    end
    max_day = [(Date.current - list.sent_on).to_i, 0].max
    days = (0..max_day).to_a

    day_counts = Hash.new { |h, k| h[k] = Hash.new(0) }
    repurchases.each do |email, rep|
      day = (rep["order_date"].to_date - list.sent_on).to_i.clamp(0, max_day)
      day_counts[segment_by_email.fetch(email, "未分類")][day] += 1
    end

    series = segment_by_email.values.uniq.sort.map do |segment|
      cumulative = 0
      { name: segment, data: days.map { |d| cumulative += day_counts[segment][d] } }
    end

    { days: days, series: series }
  end

  def build_stats(list, repurchases)
    total = @recipient_counts ? @recipient_counts.fetch(list.id, 0) : list.recipients.size
    repurchased = repurchases.size
    days = repurchases.values.map { |r| (r["order_date"].to_date - list.sent_on).to_i }
    {
      total: total,
      repurchased: repurchased,
      rate: total.positive? ? (repurchased * 100.0 / total).round(1) : nil,
      avg_days: days.any? ? (days.sum.to_f / days.size).round(1) : nil,
      revenue: repurchases.values.sum { |r| r["order_total"].to_i }
    }
  end

  def connection
    ActiveRecord::Base.connection
  end
end

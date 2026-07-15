# path: app/controllers/message_lists_controller.rb
# frozen_string_literal: true

# 訊息名單追蹤：每批名單記錄傳送日期與目標商品，
# 回購成效即時比對 shopline_orders（傳送日起、已付款、含目標商品的訂單才算）。
class MessageListsController < ApplicationController
  MEMBERSHIP_RANK = { "黑卡" => 1, "金卡" => 2, "銀卡" => 3, "白卡" => 4, "一般會員" => 5 }.freeze

  def index
    @lists = MessageList.order(sent_on: :desc, id: :desc).to_a
    @recipient_counts = MessageListRecipient.group(:message_list_id).count
    @stats = @lists.to_h { |list| [list.id, build_stats(list, repurchases_for(list))] }
  end

  def show
    @list = MessageList.find(params[:id])
    @tab = %w[repurchased pending].include?(params[:tab]) ? params[:tab] : "repurchased"

    @repurchases = repurchases_for(@list)
    @stats = build_stats(@list, @repurchases)

    recipients = sorted_recipients(@list)
    @repurchased_rows, @pending_rows = recipients.partition { |r| @repurchases.key?(r.email) }
    @rows = @tab == "repurchased" ? @repurchased_rows : @pending_rows
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

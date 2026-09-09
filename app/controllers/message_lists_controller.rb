# path: app/controllers/message_lists_controller.rb
# frozen_string_literal: true

# 訊息名單追蹤：每批名單記錄傳送日期與目標商品，
# 回購成效即時比對 shopline_orders（傳送日起、已付款、含目標商品的訂單才算）。
class MessageListsController < ApplicationController
  MEMBERSHIP_RANK = { "黑卡" => 1, "金卡" => 2, "銀卡" => 3, "白卡" => 4, "一般會員" => 5 }.freeze

  # 升級名單專用的維護資訊（距離下一級、購買品項）——卡別由低到高排序，
  # 跟上面 MEMBERSHIP_RANK（顯示排序用，黑卡最前）方向相反，這裡要的是「下一級是誰」。
  TIER_PROGRESSION = %w[一般會員 白卡 銀卡 金卡 黑卡].freeze
  UPGRADE_TIERS = %w[白卡 銀卡 金卡 黑卡].freeze
  CORE_PRODUCTS = %w[代謝錠 全能 清纖粉 益生菌 私密粉 穀胱甘肽 薑黃 魚油 膠原蛋白].freeze

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

    @is_upgrade_list = UPGRADE_TIERS.include?(@list.target_product)
    @upgrade_info = @is_upgrade_list ? build_upgrade_info(@list, recipients) : {}
  end

  def update
    list = MessageList.find(params[:id])
    list.update!(params.require(:message_list).permit(:message_content))
    redirect_to message_list_path(list), notice: "訊息內容已儲存"
  end

  # 名單裡每個人自己的維護紀錄（本次維護日期／維護內容勾選／客人狀態／下次追蹤日），
  # 跟系統自動判斷的回購成效分開記錄——姐姐聯繫完客人就直接在名單上填，不用等回購。
  BOOLEAN_RECIPIENT_FIELDS = MessageListRecipient::MAINTENANCE_CONTENT_FIELDS.keys.freeze
  DATE_RECIPIENT_FIELDS    = %w[maintenance_date next_follow_up_date].freeze
  SELECT_RECIPIENT_FIELDS  = %w[customer_status].freeze
  EDITABLE_RECIPIENT_FIELDS = (BOOLEAN_RECIPIENT_FIELDS + DATE_RECIPIENT_FIELDS + SELECT_RECIPIENT_FIELDS).freeze

  def update_recipient_field
    field = params[:field].to_s
    return head :bad_request unless EDITABLE_RECIPIENT_FIELDS.include?(field)

    recipient = MessageListRecipient.find(params[:recipient_id])
    value =
      if BOOLEAN_RECIPIENT_FIELDS.include?(field)
        ActiveModel::Type::Boolean.new.cast(params[:value])
      elsif SELECT_RECIPIENT_FIELDS.include?(field)
        return head :bad_request if params[:value].present? && !MessageListRecipient::CUSTOMER_STATUS_OPTIONS.include?(params[:value])

        params[:value].presence
      else
        params[:value].presence
      end
    recipient.update!(field => value)
    head :ok
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

  # 升級名單每個人旁邊的「距離下一級／這次購買／最近購買／還沒買過」——
  # 用現在的即時卡別與消費（不是名單建立當下的快照），因為姐姐是之後才打電話維護，
  # 這幾天可能又有新訂單進來。回傳 { recipient_id => { ... } }。
  def build_upgrade_info(list, recipients)
    customer_ids = recipients.filter_map(&:shopline_customer_id)
    return {} if customer_ids.empty?

    customers = ShoplineCustomer.where(id: customer_ids).index_by(&:id)
    latest_products    = latest_order_products(customer_ids)
    this_time_products = latest_order_products(customer_ids, on_or_before: list.sent_on)
    bought_products     = bought_core_products(customer_ids)
    threshold_cache = {}

    recipients.each_with_object({}) do |r, out|
      customer = customers[r.shopline_customer_id]
      next unless customer

      current_level = customer.membership_level
      tier_index = TIER_PROGRESSION.index(current_level)
      next_level = tier_index && TIER_PROGRESSION[tier_index + 1]

      amount_needed = nil
      if next_level
        threshold_cache[next_level] ||= tier_threshold_estimate(next_level)
        amount_needed = [threshold_cache[next_level].to_f - customer.total_amount.to_f, 0].max
      end

      out[r.id] = {
        current_level: current_level,
        next_level: next_level,
        amount_needed: amount_needed,
        this_time_product: this_time_products[customer.id],
        latest_product: latest_products[customer.id],
        never_bought: CORE_PRODUCTS - (bought_products[customer.id] || [])
      }
    end
  end

  # 該卡別現有持卡人消費金額後 5%——系統沒有存官方門檻金額，用這個當估計值
  # （跟 9/8 會員卡別流動報告用的同一套推算方法）。
  def tier_threshold_estimate(level)
    connection.select_value(<<~SQL).to_f
      SELECT percentile_disc(0.05) WITHIN GROUP (ORDER BY total_amount)
      FROM shopline_customers
      WHERE membership_level = #{connection.quote(level)}
    SQL
  end

  # 每位顧客最新一筆已付款訂單的商品名稱；on_or_before 給的話只看那個日期（含）以前。
  def latest_order_products(customer_ids, on_or_before: nil)
    date_filter = on_or_before ? "AND order_date <= #{connection.quote(on_or_before)}" : ""
    sql = <<~SQL
      SELECT DISTINCT ON (shopline_customer_id) shopline_customer_id, product_name, order_date
      FROM shopline_orders
      WHERE shopline_customer_id IN (#{customer_ids.join(',')})
        AND payment_status = '已付款'
        #{date_filter}
      ORDER BY shopline_customer_id, order_date DESC
    SQL
    connection.select_all(sql).to_a.to_h { |r| [r["shopline_customer_id"].to_i, r["product_name"]] }
  end

  # 每位顧客買過哪些公司核心商品（子字串比對，跟訂單裡實際的商品名稱，例如「魚油12送1」）。
  def bought_core_products(customer_ids)
    sql = <<~SQL
      SELECT shopline_customer_id, ARRAY_AGG(DISTINCT product_name) AS names
      FROM shopline_orders
      WHERE shopline_customer_id IN (#{customer_ids.join(',')})
        AND payment_status = '已付款'
      GROUP BY shopline_customer_id
    SQL
    connection.select_all(sql).to_a.to_h do |r|
      product_names = r["names"].is_a?(String) ? r["names"].delete_prefix("{").delete_suffix("}").split(",") : Array(r["names"])
      matched = CORE_PRODUCTS.select { |core| product_names.any? { |n| n.include?(core) } }
      [r["shopline_customer_id"].to_i, matched]
    end
  end
end

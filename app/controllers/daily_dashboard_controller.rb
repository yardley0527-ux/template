class DailyDashboardController < ApplicationController
  include ActionView::Helpers::NumberHelper

  TIERS                = %w[黑卡 金卡 銀卡 白卡 一般會員].freeze
  DAILY_TARGET         = 150_000
  HIGH_REVENUE_TARGET  = 500_000
  NEW_DAILY_THRESHOLD  =  10_000
  OLD_DAILY_THRESHOLD  = 100_000
  NEW_CUSTOMER_MIN     =       3  # 新客少於此數觸發警示
  TIER_HIGHLIGHT_PCT   =      40  # 卡別貢獻超過此 % 觸發 highlight
  MISSING_PRODUCT_DAYS =       7  # 幾天內有售但今天沒售 = 提醒

  ORDER_TOTAL_SQL = <<~SQL.squish.freeze
    CASE
      WHEN MAX(NULLIF(o.total_amount, 0)) IS NOT NULL THEN MAX(NULLIF(o.total_amount, 0))
      ELSE SUM(COALESCE(o.checkout_amount, 0))
    END
  SQL

  def index
    @start_date    = parse_date(params[:start_date]) || Date.yesterday
    @end_date      = parse_date(params[:end_date]) || @start_date
    @end_date      = @start_date if @end_date < @start_date
    @summary              = build_summary(@start_date, @end_date)
    @product_stats        = build_product_stats(@start_date, @end_date)
    @daily_stats          = build_daily_stats(@start_date, @end_date)
    @daily_customer_stats = build_daily_customer_stats(@start_date, @end_date)
    @alerts               = build_alerts(@end_date)
  end

  private

  # ── 今日提醒 ────────────────────────────────────────────────────────────

  def build_alerts(target_date)
    today   = fetch_day_summary(target_date)
    prev    = fetch_day_summary(target_date - 1)
    missing = fetch_missing_products(today[:product_names], target_date)

    alerts = []

    # 高營收 / 未達標
    if today[:total] >= HIGH_REVENUE_TARGET
      prev_txt = prev[:total] > 0 ? "，前一天 NT$#{fmt(prev[:total])}" : ""
      alerts << { icon: "🔥", type: :highlight,
                  text: "高營收！NT$#{fmt(today[:total])}#{prev_txt}" }
    elsif today[:total] < DAILY_TARGET
      diff = prev[:total] > 0 ? "，較前一天 #{signed_pct(today[:total], prev[:total])}" : ""
      alerts << { icon: "⚠", type: :warning,
                  text: "未達標（NT$#{fmt(today[:total])}#{diff}）" }
    end

    # 新客人數
    if today[:new_customers] < NEW_CUSTOMER_MIN
      alerts << { icon: "⚠", type: :warning,
                  text: "新客只有 #{today[:new_customers]} 人（前一天 #{prev[:new_customers]} 人）" }
    end

    # 卡別貢獻 > TIER_HIGHLIGHT_PCT %
    if today[:total] > 0
      today[:tiers].each do |tier|
        pct = (tier[:amount] / today[:total] * 100).round
        next if pct < TIER_HIGHLIGHT_PCT
        prev_tier = prev[:tiers].find { |t| t[:label] == tier[:label] }
        prev_pct  = prev[:total] > 0 && prev_tier ? "（前一天 #{(prev_tier[:amount] / prev[:total] * 100).round}%）" : ""
        alerts << { icon: "🔥", type: :highlight,
                    text: "#{tier[:label]}貢獻 #{pct}%#{prev_pct}" }
      end
    end

    # Top 1 商品（今天訂單數最多的商品）
    if today[:top_product]
      alerts << { icon: "🔥", type: :highlight, text: "Top1：#{today[:top_product]}" }
    end

    # 近 N 天有售、今天 0 單
    missing.first(5).each do |name|
      alerts << { icon: "⚠", type: :warning,
                  text: "#{name} 今天 0 單（近 #{MISSING_PRODUCT_DAYS} 天有售出）" }
    end

    # 全部正常
    if alerts.none? { |a| a[:type] == :warning }
      alerts << { icon: "✅", type: :info, text: "業績達標，無異常" }
    end

    alerts.sort_by { |a| { warning: 0, highlight: 1, info: 2 }[a[:type]] }
  end

  def fetch_day_summary(date)
    rs = date.beginning_of_day
    re = date.end_of_day

    raw = ShoplineOrder.from("shopline_orders o")
      .joins("LEFT JOIN shopline_customers sc ON sc.email = o.email")
      .select(
        "o.order_number",
        "MAX(COALESCE(sc.email, o.email)) AS email_val",
        "MAX(COALESCE(sc.membership_level, o.membership_level)) AS membership_level_col",
        "#{ORDER_TOTAL_SQL} AS order_total",
        "ARRAY_AGG(DISTINCT o.product_name) FILTER (WHERE o.product_name IS NOT NULL) AS product_names_arr"
      )
      .where("o.payment_status = '已付款'")
      .where("o.order_date >= ? AND o.order_date <= ?", rs, re)
      .group("o.order_number")
      .to_a

    emails = raw.map(&:email_val).compact.reject(&:blank?).uniq
    prior_emails = emails.any? ? ShoplineOrder.where(email: emails)
      .where("order_date < ?", rs)
      .distinct.pluck(:email).to_set : Set.new

    new_rows = raw.select { |o| o.email_val.blank? || !prior_emails.include?(o.email_val) }
    old_rows = raw - new_rows
    total    = raw.sum { |o| o.order_total.to_f }

    tiers = TIERS.map do |tier|
      matched = old_rows.select { |o| o.membership_level_col == tier }
      { label: tier, amount: matched.sum { |o| o.order_total.to_f } }
    end

    product_counts = Hash.new(0)
    raw.each do |o|
      Array(o.product_names_arr).compact.each do |p|
        name = p.to_s.strip
        product_counts[name] += 1 if name.present?
      end
    end

    {
      order_count:   raw.size,
      total:         total,
      new_customers: new_rows.map { |o| o.email_val.presence }.compact.uniq.size +
                     new_rows.count { |o| o.email_val.blank? },
      old_customers: old_rows.map { |o| o.email_val.presence }.compact.uniq.size,
      tiers:         tiers,
      product_names: product_counts.keys,
      top_product:   product_counts.max_by { |_, v| v }&.first
    }
  end

  def fetch_missing_products(today_product_names, date)
    window_start = (date - MISSING_PRODUCT_DAYS).beginning_of_day
    window_end   = (date - 1).end_of_day
    return [] if window_end < window_start

    recent = ShoplineOrder.where(payment_status: "已付款")
      .where("order_date >= ? AND order_date <= ?", window_start, window_end)
      .distinct.pluck(:product_name)
      .reject(&:blank?)
      .map(&:strip)
      .to_set

    today_set = today_product_names.map(&:strip).to_set
    (recent - today_set).sort.to_a
  end

  def fmt(n)
    number_with_delimiter(n.to_i)
  end

  def signed_pct(current, prev)
    return "" if prev.zero?
    pct = ((current.to_f - prev.to_f) / prev.to_f * 100).round
    "#{pct >= 0 ? '+' : ''}#{pct}%"
  end

  # ────────────────────────────────────────────────────────────────────────

  def parse_date(value)
    Date.parse(value) if value.present?
  rescue ArgumentError
    nil
  end

  def build_summary(start_date, end_date)
    range_start = start_date.beginning_of_day
    range_end   = end_date.end_of_day

    raw = ShoplineOrder.from("shopline_orders o")
      .joins("LEFT JOIN shopline_customers sc ON sc.email = o.email")
      .select(
        "o.order_number",
        "MAX(COALESCE(sc.email, o.email)) AS email_val",
        "MAX(COALESCE(sc.membership_level, o.membership_level)) AS membership_level_col",
        "#{ORDER_TOTAL_SQL} AS order_total"
      )
      .where("o.payment_status = '已付款'")
      .where("o.order_date >= ? AND o.order_date <= ?", range_start, range_end)
      .group("o.order_number")
      .to_a

    emails = raw.map(&:email_val).compact.uniq
    prior_emails = ShoplineOrder.where(email: emails)
      .where("order_date < ?", range_start)
      .distinct.pluck(:email).to_set

    new_orders = []
    old_orders = []
    raw.each do |o|
      if o.email_val.blank? || !prior_emails.include?(o.email_val)
        new_orders << o
      else
        old_orders << o
      end
    end

    old_by_tier = TIERS.map do |tier|
      matched = old_orders.select { |o| o.membership_level_col == tier }
      { label: tier, count: matched.size, amount: matched.sum { |o| o.order_total.to_f } }
    end
    ungrouped = old_orders.reject { |o| TIERS.include?(o.membership_level_col) }
    old_by_tier << { label: "未分級", count: ungrouped.size, amount: ungrouped.sum { |o| o.order_total.to_f } } if ungrouped.any?

    {
      new_count:   new_orders.size,
      new_amount:  new_orders.sum { |o| o.order_total.to_f },
      old_count:   old_orders.size,
      old_amount:  old_orders.sum { |o| o.order_total.to_f },
      old_by_tier: old_by_tier
    }
  end

  def build_product_stats(start_date, end_date)
    range_start = start_date.beginning_of_day
    range_end   = end_date.end_of_day

    raw = ShoplineOrder.from("shopline_orders o")
      .joins("LEFT JOIN shopline_customers sc ON sc.email = o.email")
      .select(
        "o.order_number",
        "o.product_name",
        "o.quantity",
        "COALESCE(o.checkout_amount, 0) AS checkout_amount",
        "COALESCE(sc.email, o.email) AS email_val",
        "COALESCE(sc.membership_level, o.membership_level) AS membership_level_col"
      )
      .where("o.payment_status = '已付款'")
      .where("o.order_date >= ? AND o.order_date <= ?", range_start, range_end)
      .to_a

    return [] if raw.empty?

    emails = raw.map(&:email_val).compact.uniq
    prior_emails = ShoplineOrder.where(email: emails)
      .where("order_date < ?", range_start)
      .distinct.pluck(:email).to_set

    order_type = {}
    raw.each do |r|
      next if order_type.key?(r.order_number)
      email = r.email_val
      if email.blank? || !prior_emails.include?(email)
        order_type[r.order_number] = "新客"
      else
        level = r.membership_level_col.to_s.presence
        order_type[r.order_number] = TIERS.include?(level) ? level : "未分級"
      end
    end

    all_types = ["新客", *TIERS, "未分級"]
    buckets = Hash.new do |h, k|
      h[k] = {
        orders: Set.new, quantity: 0, amount: 0.0,
        by_type: all_types.index_with { { orders: Set.new, amount: 0.0 } }
      }
    end

    raw.each do |r|
      name = r.product_name.to_s.strip
      next if name.blank?
      b = buckets[name]
      b[:orders] << r.order_number
      b[:quantity] += r.quantity.to_i
      b[:amount]   += r.checkout_amount.to_f
      ctype = order_type[r.order_number] || "未分級"
      b[:by_type][ctype][:orders] << r.order_number
      b[:by_type][ctype][:amount] += r.checkout_amount.to_f
    end

    total = buckets.values.sum { |b| b[:amount] }

    buckets.map do |name, b|
      {
        name:        name,
        quantity:    b[:quantity],
        order_count: b[:orders].size,
        amount:      b[:amount],
        share:       total > 0 ? (b[:amount] / total * 100).round(1) : 0.0,
        by_type:     all_types.map { |t| bt = b[:by_type][t]; { type: t, order_count: bt[:orders].size, amount: bt[:amount] } }
      }
    end
      .sort_by { |p| -p[:amount] }
      .first(5)
      .each_with_index.map { |p, i| p.merge(rank: i + 1) }
  end

  def build_daily_customer_stats(start_date, end_date)
    range_start = start_date.beginning_of_day
    range_end   = end_date.end_of_day

    raw = ShoplineOrder.from("shopline_orders o")
      .select(
        "o.order_number",
        "DATE(MAX(o.order_date)) AS order_day",
        "MAX(COALESCE(o.email, '')) AS email_val",
        "#{ORDER_TOTAL_SQL} AS order_total"
      )
      .where("o.payment_status = '已付款'")
      .where("o.order_date >= ? AND o.order_date <= ?", range_start, range_end)
      .group("o.order_number")
      .to_a

    return (start_date..end_date).map { |d| empty_day(d) } if raw.empty?

    emails       = raw.map(&:email_val).reject(&:blank?).uniq
    prior_emails = ShoplineOrder.where(email: emails)
      .where("order_date < ?", range_start)
      .distinct.pluck(:email).to_set

    by_day = {}
    raw.each do |o|
      day = o.order_day.to_date
      by_day[day] ||= {
        new: { emails: Set.new, orders: 0, amount: 0.0 },
        old: { emails: Set.new, orders: 0, amount: 0.0 }
      }
      is_new = o.email_val.blank? || !prior_emails.include?(o.email_val)
      bucket = is_new ? :new : :old
      by_day[day][bucket][:emails] << o.email_val unless o.email_val.blank?
      by_day[day][bucket][:orders] += 1
      by_day[day][bucket][:amount] += o.order_total.to_f
    end

    (start_date..end_date).map do |date|
      d = by_day[date]
      next empty_day(date) unless d

      new_d = d[:new]
      old_d = d[:old]
      new_avg = new_d[:orders] > 0 ? (new_d[:amount] / new_d[:orders]) : nil
      old_avg = old_d[:orders] > 0 ? (old_d[:amount] / old_d[:orders]) : nil

      {
        date:          date,
        new_customers: new_d[:emails].size,
        new_orders:    new_d[:orders],
        new_amount:    new_d[:amount],
        new_avg:       new_avg,
        old_customers: old_d[:emails].size,
        old_orders:    old_d[:orders],
        old_amount:    old_d[:amount],
        old_avg:       old_avg
      }
    end
  end

  def empty_day(date)
    { date: date, new_customers: 0, new_orders: 0, new_amount: 0.0, new_avg: nil,
      old_customers: 0, old_orders: 0, old_amount: 0.0, old_avg: nil }
  end

  def build_daily_stats(start_date, end_date)
    range_start = start_date.beginning_of_day
    range_end   = end_date.end_of_day

    raw = ShoplineOrder.from("shopline_orders o")
      .select(
        "DATE(o.order_date) AS order_day",
        "o.order_number",
        "#{ORDER_TOTAL_SQL} AS order_total"
      )
      .where("o.payment_status = '已付款'")
      .where("o.order_date >= ? AND o.order_date <= ?", range_start, range_end)
      .group("DATE(o.order_date), o.order_number")
      .to_a

    by_day = raw.group_by { |r| r.order_day.to_date }

    (start_date..end_date).map do |date|
      orders = by_day[date] || []
      count  = orders.size
      total  = orders.sum { |o| o.order_total.to_f }
      avg    = count > 0 ? (total / count) : 0
      { date: date, order_count: count, total_amount: total, avg_amount: avg, met_target: total >= DAILY_TARGET }
    end
  end
end

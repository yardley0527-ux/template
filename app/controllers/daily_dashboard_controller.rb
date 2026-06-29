class DailyDashboardController < ApplicationController
  include ActionView::Helpers::NumberHelper

  TIERS                = %w[黑卡 金卡 銀卡 白卡 一般會員].freeze
  DAILY_TARGET         = 150_000
  HIGH_REVENUE_TARGET  = 500_000
  NEW_DAILY_THRESHOLD  =  10_000
  OLD_DAILY_THRESHOLD  = 100_000
  NEW_CUSTOMER_MIN     =       3   # 新客少於此數觸發 critical
  TIER_HIGHLIGHT_PCT   =      40   # 卡別佔比超過此 % 顯示 highlight
  MISSING_PRODUCT_DAYS =       7   # 幾天內有售但今天無單 = 商品提醒
  REVENUE_DROP_PCT     =      20   # 較昨日下降超過此 % 觸發 critical

  ORDER_TOTAL_SQL = <<~SQL.squish.freeze
    CASE
      WHEN MAX(NULLIF(o.total_amount, 0)) IS NOT NULL THEN MAX(NULLIF(o.total_amount, 0))
      ELSE SUM(COALESCE(o.checkout_amount, 0))
    END
  SQL

  def index
    if params[:start_date].blank? && params[:end_date].blank?
      @end_date   = Time.zone.yesterday
      # 週一自動帶入週五～週日（上班日沒進訂單，週末三天一起看）
      @start_date = Time.zone.today.monday? ? @end_date - 2 : @end_date
    else
      @start_date = parse_date(params[:start_date]) || Time.zone.yesterday
      @end_date   = parse_date(params[:end_date])   || @start_date
      @end_date   = @start_date if @end_date < @start_date
    end
    @summary              = build_summary(@start_date, @end_date)
    @product_stats        = build_product_stats(@start_date, @end_date)
    @daily_stats          = build_daily_stats(@start_date, @end_date)
    @daily_customer_stats = build_daily_customer_stats(@start_date, @end_date)
    @alerts               = build_alerts(@start_date, @end_date)
  end

  private

  # ── 今日提醒（三區塊）────────────────────────────────────────────────────

  # start_date == end_date → 單日模式（與前一天比）
  # start_date < end_date  → 區間模式（週一跨週末等，與前一個相同天數比）
  def build_alerts(start_date, end_date)
    days_count = (end_date - start_date).to_i + 1

    if days_count == 1
      # 單日：比較前一天
      today      = fetch_day_summary(end_date)
      prev       = fetch_day_summary(end_date - 1)
      week_stats = fetch_product_week_stats(end_date)
      weekly_nc  = fetch_weekly_new_customer_avg(end_date)
      period_label = nil
    else
      # 多日（例如週一含五六日）：比較前一個相同天數的區間
      today      = fetch_range_summary(start_date, end_date)
      prev_end   = start_date - 1
      prev_start = prev_end - days_count + 1
      prev       = fetch_range_summary(prev_start, prev_end)
      week_stats = fetch_product_week_stats(end_date)
      weekly_nc  = fetch_weekly_new_customer_avg(end_date)
      period_label = "#{start_date.strftime('%-m/%-d')}～#{end_date.strftime('%-m/%-d')}"
    end

    missing_products = (week_stats.keys.to_set - today[:product_names].to_set).sort

    {
      critical:       build_critical_alerts(today, prev, weekly_nc, period_label).first(3),
      highlights:     build_highlight_alerts(today, prev, period_label).first(3),
      product_alerts: missing_products.map { |name|
        h = week_stats[name] || {}
        { name: name, today: 0, yesterday: h[:yesterday].to_i,
          week_avg: h[:week_avg] || 0.0, week_total: h[:week_total].to_i }
      },
      period_label: period_label
    }
  end

  def build_critical_alerts(today, prev, weekly_nc = 0, period_label = nil)
    alerts = []

    cur_label  = period_label || "昨日"
    prev_label = period_label ? "前期" : "前日"

    # 未達標
    daily_target = period_label ? DAILY_TARGET * ((today[:days] || 1)) : DAILY_TARGET
    if today[:total] < daily_target
      pct_change = prev[:total] > 0 ? ((today[:total] - prev[:total]) / prev[:total].to_f * 100).round : nil
      vs_label   = pct_change ? arrow_pct(pct_change) : "—"
      alerts << {
        title: "#{cur_label}營收未達標",
        lines: [
          { label: cur_label,   value: "NT$#{fmt(today[:total])}" },
          { label: "目標",      value: "NT$#{fmt(daily_target)}" },
          { label: "較#{prev_label}", value: vs_label, down: pct_change&.<(0) }
        ]
      }
    end

    # 新客人數不足
    new_min = period_label ? NEW_CUSTOMER_MIN * (today[:days] || 1) : NEW_CUSTOMER_MIN
    if today[:new_customers] < new_min
      title = today[:new_customers] == 0 ? "#{cur_label}沒有新客" : "#{cur_label}新客只有 #{today[:new_customers]} 人"
      alerts << {
        title: title,
        lines: [
          { label: cur_label,        value: "#{today[:new_customers]} 人" },
          { label: prev_label,       value: "#{prev[:new_customers]} 人" },
          { label: "近 7 日平均", value: "#{weekly_nc} 人" }
        ]
      }
    end

    # 達標但大幅下滑
    if today[:total] >= daily_target && prev[:total] > 0
      pct = ((today[:total] - prev[:total]) / prev[:total].to_f * 100).round
      if pct <= -REVENUE_DROP_PCT
        alerts << {
          title: "#{cur_label}營收較#{prev_label}大幅下降",
          lines: [
            { label: cur_label,   value: "NT$#{fmt(today[:total])}" },
            { label: prev_label,  value: "NT$#{fmt(prev[:total])}" },
            { label: "變化",      value: arrow_pct(pct), down: true }
          ]
        }
      end
    end

    alerts
  end

  def build_highlight_alerts(today, prev, period_label = nil)
    alerts = []

    cur_label  = period_label || "昨日"
    prev_label = period_label ? "前期" : "前日"
    hi_target  = period_label ? HIGH_REVENUE_TARGET * (today[:days] || 1) : HIGH_REVENUE_TARGET

    # 高營收
    if today[:total] >= hi_target
      pct = prev[:total] > 0 ? ((today[:total] - prev[:total]) / prev[:total].to_f * 100).round : nil
      alerts << {
        title: "#{cur_label}高營收達成",
        lines: [
          { label: "#{cur_label}營收", value: "NT$#{fmt(today[:total])}", up: true },
          { label: "較#{prev_label}",  value: pct ? arrow_pct(pct) : "—", up: pct&.>(0), down: pct&.<(0) }
        ]
      }
    elsif today[:total] >= DAILY_TARGET && prev[:total] > 0
      pct = ((today[:total] - prev[:total]) / prev[:total].to_f * 100).round
      if pct >= REVENUE_DROP_PCT
        alerts << {
          title: "#{cur_label}營收顯著成長",
          lines: [
            { label: cur_label,          value: "NT$#{fmt(today[:total])}", up: true },
            { label: "較#{prev_label}",  value: arrow_pct(pct), up: true }
          ]
        }
      end
    end

    # Top 1 商品（訂單數優先，金額為副）
    if today[:top_product_detail]
      tp    = today[:top_product_detail]
      share = today[:total] > 0 ? (tp[:amount] / today[:total] * 100).round : 0
      alerts << {
        title:        "#{cur_label} Top1 商品",
        kind:         :top_product,
        product_name: tp[:name],
        lines: [
          { label: "訂單數",          value: "#{tp[:count]} 單" },
          { label: "營業額",          value: "NT$#{fmt(tp[:amount])}" },
          { label: "佔#{cur_label}營收", value: "#{share}%" }
        ]
      }
    end

    # 最高貢獻卡別（佔整體 >= TIER_HIGHLIGHT_PCT%）
    if today[:total] > 0
      top_tier = today[:tiers].select { |t| t[:amount] > 0 }.max_by { |t| t[:amount] }
      if top_tier
        pct_total = (top_tier[:amount] / today[:total] * 100).round
        if pct_total >= TIER_HIGHLIGHT_PCT
          old_total = today[:old_total]
          pct_old   = old_total > 0 ? (top_tier[:amount] / old_total * 100).round : pct_total
          prev_tier = prev[:tiers].find { |t| t[:label] == top_tier[:label] }
          vs_prev   = if prev[:total] > 0 && prev_tier && prev_tier[:amount] > 0
            ((top_tier[:amount] - prev_tier[:amount]) / prev_tier[:amount].to_f * 100).round
          end
          alerts << {
            title: "#{cur_label}最高貢獻會員卡",
            lines: [
              { label: "卡別",            value: top_tier[:label] },
              { label: "營收",            value: "NT$#{fmt(top_tier[:amount])}" },
              { label: "佔舊客營收",      value: "#{pct_old}%" },
              { label: "較#{prev_label}", value: vs_prev ? arrow_pct(vs_prev) : "—",
                up: vs_prev&.>(0), down: vs_prev&.<(0) }
            ]
          }
        end
      end
    end

    alerts
  end

  # ── 查詢輔助 ──────────────────────────────────────────────────────────────

  def fetch_range_summary(start_date, end_date)
    rs = start_date.beginning_of_day
    re = end_date.end_of_day
    days = (end_date - start_date).to_i + 1

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

    new_rows  = raw.select { |o| o.email_val.blank? || !prior_emails.include?(o.email_val) }
    old_rows  = raw - new_rows
    total     = raw.sum { |o| o.order_total.to_f }
    old_total = old_rows.sum { |o| o.order_total.to_f }

    tiers = TIERS.map do |tier|
      matched = old_rows.select { |o| o.membership_level_col == tier }
      { label: tier, amount: matched.sum { |o| o.order_total.to_f } }
    end

    product_names = raw.flat_map { |o| Array(o.product_names_arr).compact.map(&:strip) }
                       .reject(&:blank?).uniq

    product_revenues = ShoplineOrder.where(payment_status: "已付款")
      .where("order_date >= ? AND order_date <= ?", rs, re)
      .where.not(product_name: [nil, ""])
      .select("product_name, COUNT(DISTINCT order_number) AS cnt, SUM(COALESCE(checkout_amount, 0)) AS revenue")
      .group(:product_name)
      .map { |r| { name: r.product_name.to_s.strip, count: r.cnt.to_i, amount: r.revenue.to_f } }
      .sort_by { |r| [-r[:count], -r[:amount]] }

    {
      order_count:        raw.size,
      total:              total,
      old_total:          old_total,
      new_customers:      new_rows.map { |o| o.email_val.presence }.compact.uniq.size +
                          new_rows.count { |o| o.email_val.blank? },
      old_customers:      old_rows.map { |o| o.email_val.presence }.compact.uniq.size,
      tiers:              tiers,
      product_names:      product_names,
      top_product_detail: product_revenues.first,
      days:               days
    }
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

    new_rows  = raw.select { |o| o.email_val.blank? || !prior_emails.include?(o.email_val) }
    old_rows  = raw - new_rows
    total     = raw.sum { |o| o.order_total.to_f }
    old_total = old_rows.sum { |o| o.order_total.to_f }

    tiers = TIERS.map do |tier|
      matched = old_rows.select { |o| o.membership_level_col == tier }
      { label: tier, amount: matched.sum { |o| o.order_total.to_f } }
    end

    product_names = raw.flat_map { |o| Array(o.product_names_arr).compact.map(&:strip) }
                       .reject(&:blank?).uniq

    # 依營業額排行的商品（用 checkout_amount 做 line-item 統計）
    product_revenues = ShoplineOrder.where(payment_status: "已付款")
      .where("order_date >= ? AND order_date <= ?", rs, re)
      .where.not(product_name: [nil, ""])
      .select("product_name, COUNT(DISTINCT order_number) AS cnt, SUM(COALESCE(checkout_amount, 0)) AS revenue")
      .group(:product_name)
      .map { |r| { name: r.product_name.to_s.strip, count: r.cnt.to_i, amount: r.revenue.to_f } }
      .sort_by { |r| [-r[:count], -r[:amount]] }

    {
      order_count:        raw.size,
      total:              total,
      old_total:          old_total,
      new_customers:      new_rows.map { |o| o.email_val.presence }.compact.uniq.size +
                          new_rows.count { |o| o.email_val.blank? },
      old_customers:      old_rows.map { |o| o.email_val.presence }.compact.uniq.size,
      tiers:              tiers,
      product_names:      product_names,
      top_product_detail: product_revenues.first
    }
  end

  def fetch_product_week_stats(target_date)
    window_start = (target_date - MISSING_PRODUCT_DAYS).beginning_of_day
    window_end   = (target_date - 1).end_of_day
    return {} if window_end < window_start

    raw = ShoplineOrder.where(payment_status: "已付款")
      .where("order_date >= ? AND order_date <= ?", window_start, window_end)
      .where.not(product_name: [nil, ""])
      .select("product_name, DATE(order_date) AS order_day, COUNT(DISTINCT order_number) AS cnt")
      .group("product_name, DATE(order_date)")
      .to_a

    by_product = raw.group_by { |r| r.product_name.to_s.strip }.reject { |k, _| k.blank? }

    by_product.transform_values do |rows|
      yesterday_cnt = rows.find { |r| r.order_day.to_date == target_date - 1 }&.cnt.to_i || 0
      week_total    = rows.sum { |r| r.cnt.to_i }
      {
        yesterday:  yesterday_cnt,
        week_avg:   (week_total / MISSING_PRODUCT_DAYS.to_f).round(1),
        week_total: week_total
      }
    end
  end

  def fetch_weekly_new_customer_avg(target_date)
    window_start = (target_date - 7).beginning_of_day
    window_end   = (target_date - 1).end_of_day

    raw = ShoplineOrder.where(payment_status: "已付款")
      .where("order_date >= ? AND order_date <= ?", window_start, window_end)
      .select("order_number, MAX(email) AS email, DATE(MAX(order_date)) AS order_day")
      .group(:order_number)
      .to_a

    emails = raw.map(&:email).compact.reject(&:blank?).uniq
    prior_emails = emails.any? ? ShoplineOrder.where(email: emails)
      .where("order_date < ?", window_start)
      .distinct.pluck(:email).to_set : Set.new

    by_day = Hash.new { |h, k| h[k] = Set.new }
    raw.each do |o|
      next if o.email.present? && prior_emails.include?(o.email)
      by_day[o.order_day.to_date] << (o.email.presence || o.order_number)
    end

    total = by_day.values.sum { |s| s.size }
    (total / 7.0).round(1)
  end

  def fmt(n)
    number_with_delimiter(n.to_i)
  end

  def arrow_pct(pct)
    pct >= 0 ? "▲#{pct}%" : "▼#{pct.abs}%"
  end

  # ─────────────────────────────────────────────────────────────────────────

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

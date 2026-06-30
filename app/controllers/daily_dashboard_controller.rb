class DailyDashboardController < ApplicationController
  include ActionView::Helpers::NumberHelper

  TIERS        = %w[黑卡 金卡 銀卡 白卡 一般會員].freeze
  DAILY_TARGET = 150_000

  ORDER_TOTAL_SQL = <<~SQL.squish.freeze
    CASE
      WHEN MAX(NULLIF(o.total_amount, 0)) IS NOT NULL THEN MAX(NULLIF(o.total_amount, 0))
      ELSE SUM(COALESCE(o.checkout_amount, 0))
    END
  SQL

  def index
    if params[:start_date].blank? && params[:end_date].blank?
      @end_date   = Time.zone.yesterday
      @start_date = Time.zone.today.monday? ? @end_date - 2 : @end_date
    else
      @start_date = parse_date(params[:start_date]) || Time.zone.yesterday
      @end_date   = parse_date(params[:end_date])   || @start_date
      @end_date   = @start_date if @end_date < @start_date
    end
    @yesterday_insights   = build_yesterday_insights
    @summary              = build_summary(@start_date, @end_date)
    @product_stats        = build_product_stats(@start_date, @end_date)
    @daily_stats          = build_daily_stats(@start_date, @end_date)
    @daily_customer_stats = build_daily_customer_stats(@start_date, @end_date)
  end

  private

  # ── 昨日訂單洞察 ──────────────────────────────────────────────────────────

  def build_yesterday_insights
    yesterday = Time.zone.yesterday
    rs = yesterday.beginning_of_day
    re = yesterday.end_of_day

    raw = ShoplineOrder.from("shopline_orders o")
      .joins("LEFT JOIN shopline_customers sc ON sc.email = o.email")
      .select(
        "o.order_number",
        "MAX(COALESCE(sc.email, o.email)) AS email_val",
        "MAX(COALESCE(sc.membership_level, o.membership_level)) AS membership_level_col",
        "MAX(sc.birthdate) AS birthdate_val",
        "#{ORDER_TOTAL_SQL} AS order_total"
      )
      .where("o.payment_status = '已付款'")
      .where("o.order_date >= ? AND o.order_date <= ?", rs, re)
      .group("o.order_number")
      .to_a

    return nil if raw.empty?

    total_revenue = raw.sum { |o| o.order_total.to_f }

    emails = raw.map(&:email_val).compact.reject(&:blank?).uniq
    prior_emails = emails.any? ? ShoplineOrder.where(email: emails)
      .where("order_date < ?", rs)
      .distinct.pluck(:email).to_set : Set.new

    # A. 昨日主力商品 Top 5（依銷售數量排序）
    product_rows = ShoplineOrder
      .where(payment_status: "已付款")
      .where("order_date >= ? AND order_date <= ?", rs, re)
      .where.not(product_name: [nil, ""])
      .select(
        "product_name",
        "SUM(COALESCE(quantity, 1)) AS total_qty",
        "COUNT(DISTINCT order_number) AS order_cnt",
        "SUM(COALESCE(checkout_amount, 0)) AS revenue"
      )
      .group(:product_name)
      .order("total_qty DESC")
      .limit(5)
      .to_a

    top_products = product_rows.each_with_index.map do |r, i|
      {
        rank:        i + 1,
        name:        r.product_name.to_s.strip,
        quantity:    r.total_qty.to_i,
        order_count: r.order_cnt.to_i,
        amount:      r.revenue.to_f,
        share:       total_revenue > 0 ? (r.revenue.to_f / total_revenue * 100).round(1) : 0
      }
    end

    # 昨日主力商品：客戶類型細分（新客 / 舊客首購 / 舊客回購）
    if top_products.any?
      top_names  = top_products.map { |p| p[:name] }
      old_emails = emails.select { |e| prior_emails.include?(e) }

      # 舊客中，昨日前曾買過這些商品的 email 集合（依商品）
      prior_product_buyers = Hash.new { |h, k| h[k] = Set.new }
      if old_emails.any?
        ShoplineOrder
          .where(email: old_emails)
          .where("order_date < ?", rs)
          .where(product_name: top_names)
          .distinct.pluck(:email, :product_name)
          .each { |(email, product)| prior_product_buyers[product.to_s.strip] << email }
      end

      # 昨日各訂單 × 商品的 email（用於分類）
      li_rows = ShoplineOrder.from("shopline_orders o")
        .joins("LEFT JOIN shopline_customers sc ON sc.email = o.email")
        .where("o.payment_status = '已付款'")
        .where("o.order_date >= ? AND o.order_date <= ?", rs, re)
        .where("o.product_name IN (?)", top_names)
        .select(
          "o.order_number",
          "o.product_name",
          "MAX(COALESCE(sc.email, o.email)) AS email_val"
        )
        .group("o.order_number, o.product_name")
        .to_a

      li_by_product = li_rows.group_by { |li| li.product_name.to_s.strip }

      top_products = top_products.map do |p|
        buckets = {
          new_customer:    { emails: Set.new, orders: Set.new },
          returning_first: { emails: Set.new, orders: Set.new },
          repurchase:      { emails: Set.new, orders: Set.new }
        }

        (li_by_product[p[:name]] || []).each do |li|
          email = li.email_val.to_s.strip
          type  = if email.blank? || !prior_emails.include?(email)
            :new_customer
          elsif prior_product_buyers[p[:name]].include?(email)
            :repurchase
          else
            :returning_first
          end
          buckets[type][:emails] << email if email.present?
          buckets[type][:orders] << li.order_number
        end

        p.merge(
          by_customer_type: buckets.transform_values { |b|
            { customers: b[:emails].size, orders: b[:orders].size }
          }
        )
      end
    end

    # B. 昨日主要購買卡別
    tier_data = Hash.new { |h, k| h[k] = { emails: Set.new, orders: 0, amount: 0.0 } }

    raw.each do |o|
      is_new = o.email_val.blank? || !prior_emails.include?(o.email_val)
      tier = if is_new
        "新客"
      else
        level = o.membership_level_col.to_s.presence
        TIERS.include?(level) ? level : "未分級"
      end
      tier_data[tier][:emails] << o.email_val if o.email_val.present?
      tier_data[tier][:orders]  += 1
      tier_data[tier][:amount]  += o.order_total.to_f
    end

    by_tier = ["新客", *TIERS, "未分級"].filter_map do |tier|
      b = tier_data[tier]
      next if b[:orders] == 0
      {
        tier:           tier,
        customer_count: b[:emails].size,
        order_count:    b[:orders],
        amount:         b[:amount],
        avg_order:      (b[:amount] / b[:orders]).round
      }
    end.sort_by { |t| -t[:amount] }

    # C. 昨日主要年齡層
    today_year = Date.today.year
    age_data = Hash.new { |h, k| h[k] = { emails: Set.new, orders: 0, amount: 0.0 } }

    raw.each do |o|
      bd_raw = o.birthdate_val
      bd     = bd_raw ? (Date.parse(bd_raw.to_s) rescue nil) : nil
      band   = bd ? age_band_for(today_year - bd.year) : "未知"
      age_data[band][:emails] << o.email_val if o.email_val.present?
      age_data[band][:orders]  += 1
      age_data[band][:amount]  += o.order_total.to_f
    end

    by_age = ["未知", "20以下", "20-29", "30-39", "40-49", "50-59", "60+"].map do |band|
      b = age_data[band]
      {
        band:           band,
        customer_count: b[:emails].size,
        order_count:    b[:orders],
        amount:         b[:amount],
        avg_order:      b[:orders] > 0 ? (b[:amount] / b[:orders]).round : 0
      }
    end

    # 自動摘要
    top_old_tier = by_tier.reject { |t| t[:tier] == "新客" }.first
    top_product  = top_products.first
    top_age      = by_age.reject { |a| a[:band] == "未知" }.max_by { |a| a[:order_count] }

    parts = []
    parts << "昨日訂單主要來自【#{top_old_tier[:tier]}】"        if top_old_tier
    parts << "熱賣商品為【#{top_product[:name]}】"              if top_product
    parts << "主要購買年齡層集中在【#{top_age[:band]}歲】"        if top_age && top_age[:order_count] > 0

    {
      date:         yesterday,
      top_products: top_products,
      by_tier:      by_tier,
      by_age:       by_age,
      summary_text: parts.any? ? parts.join("，") + "。" : nil
    }
  end

  def age_band_for(age)
    case age
    when 0..19  then "20以下"
    when 20..29 then "20-29"
    when 30..39 then "30-39"
    when 40..49 then "40-49"
    when 50..59 then "50-59"
    else             "60+"
    end
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
      {
        date:          date,
        new_customers: new_d[:emails].size,
        new_orders:    new_d[:orders],
        new_amount:    new_d[:amount],
        new_avg:       new_d[:orders] > 0 ? (new_d[:amount] / new_d[:orders]) : nil,
        old_customers: old_d[:emails].size,
        old_orders:    old_d[:orders],
        old_amount:    old_d[:amount],
        old_avg:       old_d[:orders] > 0 ? (old_d[:amount] / old_d[:orders]) : nil
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

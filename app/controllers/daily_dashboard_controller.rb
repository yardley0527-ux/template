class DailyDashboardController < ApplicationController
  TIERS        = %w[黑卡 金卡 銀卡 白卡 一般會員].freeze
  DAILY_TARGET = 150_000

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
    @summary       = build_summary(@start_date, @end_date)
    @product_stats = build_product_stats(@start_date, @end_date)
    @daily_stats   = build_daily_stats(@start_date, @end_date)
  end

  private

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

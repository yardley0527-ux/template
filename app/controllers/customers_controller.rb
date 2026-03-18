# frozen_string_literal: true

class CustomersController < ApplicationController
  PER_PAGE = 50
  MAX_PAGE = 200

  def index
    @q = params[:q].to_s.strip
    @city = params[:city].to_s.strip
    @membership_level = params[:membership_level].to_s.strip
    @min_credits = to_number(params[:min_credits])
    @sort = params[:sort].to_s.strip.presence || "amount_desc"

    @membership_levels = ShoplineCustomer.distinct.pluck(:membership_level).compact.sort

    @page = params[:page].to_i
    @page = 1 if @page <= 0
    @page = MAX_PAGE if @page > MAX_PAGE

    @city_by_membership = ShoplineCustomer
      .where.not(membership_level: [nil, ""])
      .where.not(city: [nil, ""])
      .group(:membership_level, :city)
      .count
      .each_with_object(Hash.new { |h, k| h[k] = {} }) do |((level, city), cnt), h|
        h[level][city] = cnt
      end

    @membership_order = %w[黑卡 金卡 銀卡 白卡 一般會員]

    scope = ShoplineCustomer.all

    if @q.present?
      like = "%#{@q}%"
      scope = scope.where(
        "full_name ILIKE :like OR email ILIKE :like OR mobile_phone ILIKE :like OR phone ILIKE :like OR instagram_account ILIKE :like",
        like: like
      )
    end

    scope = scope.where("city ILIKE ?", "%#{@city}%") if @city.present?
    scope = scope.where(membership_level: @membership_level) if @membership_level.present?
    scope = scope.where("current_shopping_credits >= ?", @min_credits) if @min_credits
    scope = scope.where.not(email: [nil, ""]).or(scope.where.not(mobile_phone: [nil, ""]))

    # 未購警示排序需要 join last_order_date
    if @sort.start_with?("inactive")
      scope = scope
        .joins(
          "LEFT JOIN (
            SELECT email, MAX(order_date) AS last_order_date
            FROM shopline_orders
            WHERE product_name IS NOT NULL AND product_name != ''
            GROUP BY email
          ) lo ON lo.email = shopline_customers.email"
        )
        .select("shopline_customers.*, lo.last_order_date")
    end

    scope = scope.reorder(Arel.sql(order_sql(@sort)))

    @total = if @sort.start_with?("inactive")
      scope.except(:select, :joins).count
    else
      scope.count
    end
    @total_pages = (@total.to_f / PER_PAGE).ceil
    @total_pages = 1 if @total_pages <= 0

    offset = (@page - 1) * PER_PAGE
    @customers = scope.offset(offset).limit(PER_PAGE)

    emails = @customers.map(&:email).compact.uniq

    orders_by_email = ShoplineOrder
      .where(email: emails)
      .where.not(product_name: [nil, ""])
      .select(:email, :product_name, :quantity)
      .group_by(&:email)

    @top_products = {}
    orders_by_email.each do |email, orders|
      series_counts = Hash.new { |h, k| h[k] = { qty: 0, count: 0 } }
      orders.each do |o|
        series, bottles_per_unit = parse_product(o.product_name)
        series_counts[series][:qty] += o.quantity.to_i * bottles_per_unit
        series_counts[series][:count] += 1
      end
      @top_products[email] = series_counts.max_by { |_, v| [v[:qty], v[:count]] }&.first
    end

    last_order_by_email = ShoplineOrder
      .where(email: emails)
      .where.not(product_name: [nil, ""])
      .select(:email, :product_name, :order_date)
      .group_by(&:email)
      .transform_values { |orders| orders.max_by(&:order_date) }

    @inactive_info = {}
    last_order_by_email.each do |email, last_order|
      next unless last_order.order_date
      days_ago = (Date.today - last_order.order_date.to_date).to_i
      if days_ago >= 60
        series, _ = parse_product(last_order.product_name)
        @inactive_info[email] = { days: days_ago, last_product: series }
      end
    end
  end

  def show
    @customer = ShoplineCustomer.find(params[:id])
    @orders = ShoplineOrder.where(email: @customer.email).order(order_date: :desc)
    @product_analysis = analyze_products(@orders)
  end

  private

  def analyze_products(orders)
    today = Date.today
    series_grouped = Hash.new { |h, k| h[k] = [] }

    orders.where.not(product_name: [nil, ""]).each do |order|
      series, bottles_per_unit = parse_product(order.product_name)
      series_grouped[series] << {
        order: order,
        bottles_per_unit: bottles_per_unit,
        bottles_total: (order.quantity.to_i * bottles_per_unit)
      }
    end

    series_grouped.map do |series_name, items|
      items_sorted = items.sort_by { |i| i[:order].order_date || Date.new(0) }
      dates = items_sorted.map { |i| i[:order].order_date&.to_date }.compact.uniq.sort

      total_qty_bottles = items.sum { |i| i[:bottles_total] }
      total_amount = items.sum { |i| i[:order].total_amount.to_f }
      order_count = items.map { |i| i[:order].order_number }.uniq.size
      last_purchase_bottles = items_sorted.last&.fetch(:bottles_total) || 0

      avg_cycle_days = if dates.size >= 2
        intervals = dates.each_cons(2).map { |a, b| (b - a).to_i }.reject { |i| i <= 0 }
        intervals.any? ? (intervals.sum.to_f / intervals.size).round : nil
      end

      avg_bottles_per_purchase = order_count > 0 ? (total_qty_bottles.to_f / order_count).round(1) : nil

      days_per_bottle = if avg_cycle_days && avg_bottles_per_purchase && avg_bottles_per_purchase > 0
        (avg_cycle_days.to_f / avg_bottles_per_purchase).round(1)
      end

      days_since_last = dates.last ? (today - dates.last).to_i : nil

      estimated_stock = if days_per_bottle && days_since_last && last_purchase_bottles > 0
        (last_purchase_bottles - (days_since_last.to_f / days_per_bottle)).round(1)
      end

      estimated_empty_date = if days_per_bottle && dates.last && last_purchase_bottles > 0
        dates.last + (last_purchase_bottles * days_per_bottle).round
      end

      overdue_days = if estimated_empty_date && today > estimated_empty_date
        (today - estimated_empty_date).to_i
      end

      {
        product_name: series_name,
        order_count: order_count,
        total_qty_bottles: total_qty_bottles,
        total_amount: total_amount,
        first_date: dates.first,
        last_date: dates.last,
        last_purchase_bottles: last_purchase_bottles,
        avg_bottles_per_purchase: avg_bottles_per_purchase,
        avg_cycle_days: avg_cycle_days,
        days_per_bottle: days_per_bottle,
        days_since_last: days_since_last,
        estimated_stock: estimated_stock,
        estimated_empty_date: estimated_empty_date,
        overdue_days: overdue_days,
        dates: dates
      }
    end.sort_by { |p| [-p[:total_qty_bottles], -p[:order_count], p[:avg_cycle_days] || Float::INFINITY] }
  end

  def parse_product(name)
    if name =~ /^(.+?)(\d+)$/
      [$1.strip, $2.to_i]
    else
      [name, 1]
    end
  end

  def to_number(v)
    s = v.to_s.strip
    return nil if s.blank?
    s = s.gsub(/[,\uFF0C]/, "")
    Float(s)
  rescue ArgumentError
    nil
  end

  def order_sql(sort)
    case sort
    when "amount_desc"    then "total_amount DESC NULLS LAST, id DESC"
    when "amount_asc"     then "total_amount ASC NULLS LAST, id DESC"
    when "orders_desc"    then "order_count DESC NULLS LAST, id DESC"
    when "orders_asc"     then "order_count ASC NULLS LAST, id DESC"
    when "credits_desc"   then "current_shopping_credits DESC NULLS LAST, id DESC"
    when "credits_asc"    then "current_shopping_credits ASC NULLS LAST, id DESC"
    when "inactive_desc"  then "lo.last_order_date ASC NULLS LAST, id DESC"
    when "inactive_asc"   then "lo.last_order_date DESC NULLS LAST, id DESC"
    when "newest"         then "created_at DESC, id DESC"
    else "total_amount DESC NULLS LAST, id DESC"
    end
  end
end
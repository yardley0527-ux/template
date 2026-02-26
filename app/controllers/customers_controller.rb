# path: app/controllers/customers_controller.rb
# frozen_string_literal: true

class CustomersController < ApplicationController
  PER_PAGE = 50
  MAX_PAGE = 200

  def index
    @q = params[:q].to_s.strip
    @city = params[:city].to_s.strip
    @member = params[:member].to_s.strip
    @min_credits = to_number(params[:min_credits])
    @min_points = to_number(params[:min_points])
    @sort = params[:sort].to_s.strip.presence || "credits_desc"

    @page = params[:page].to_i
    @page = 1 if @page <= 0
    @page = MAX_PAGE if @page > MAX_PAGE

    scope = ShoplineCustomer.all

    if @q.present?
      like = "%#{@q}%"
      scope = scope.where(
        "full_name ILIKE :like OR email ILIKE :like OR mobile_phone ILIKE :like OR phone ILIKE :like OR instagram_account ILIKE :like",
        like: like
      )
    end

    scope = scope.where("city ILIKE ?", "%#{@city}%") if @city.present?

    if @member == "1"
      scope = scope.where(is_member: true)
    elsif @member == "0"
      scope = scope.where(is_member: [false, nil])
    end

    scope = scope.where("current_shopping_credits >= ?", @min_credits) if @min_credits
    scope = scope.where("current_points >= ?", @min_points) if @min_points

    scope = scope.where.not(email: [nil, ""]).or(scope.where.not(mobile_phone: [nil, ""]))

    scope = scope.reorder(Arel.sql(order_sql(@sort)))

    @total = scope.count
    @total_pages = (@total.to_f / PER_PAGE).ceil
    @total_pages = 1 if @total_pages <= 0

    offset = (@page - 1) * PER_PAGE
    @customers = scope.offset(offset).limit(PER_PAGE)
  end

  def show
    @customer = ShoplineCustomer.find(params[:id])

    # 所有訂單，按時間排序
    @orders = ShoplineOrder.where(email: @customer.email).order(order_date: :desc)

    # 購買週期分析
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
    end.sort_by { |p| -p[:order_count] }
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
    when "points_desc"
      "current_points DESC NULLS LAST, id DESC"
    when "newest"
      "created_at DESC, id DESC"
    when "orders_desc"
      "order_count DESC NULLS LAST, id DESC"
    else
      "current_shopping_credits DESC NULLS LAST, id DESC"
    end
  end
end
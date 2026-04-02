# frozen_string_literal: true

class ProductsController < ApplicationController
  YEARS = [2026, 2025, 2024].freeze
  
  def index
    @q = params[:q].to_s.strip
    @sort = params[:sort].to_s.strip.presence || "revenue"
    @combo = params[:combo] == "1" 

    @years = YEARS
    @top_by_year = @years.index_with { |y| top_products_for_year(y, q: @q, sort: @sort, limit: 10, combo: @combo) }
    @order_counts_by_year = ShoplineOrder.group(:source_year).count.sort.reverse.to_h

    @buyer_stats_by_year = @years.index_with do |y|
      names = @top_by_year[y].map(&:product_name)
      names.any? ? buyer_stats(names, y) : {}
    end
  end

  def show
    raw = params[:id].to_s

    # sidebar 用 CGI.escape，偶爾會 double-escape
    decoded = CGI.unescape(raw)
    decoded = CGI.unescape(decoded) if decoded.include?("%")
    @product_name = decoded.strip

    scope = ShoplineOrder.where(product_name: @product_name)
    raise ActiveRecord::RecordNotFound, "product not found: #{@product_name}" if scope.none?

    revenue_col = revenue_column

    orders_count = scope.count
    units_sold   = scope.sum(:quantity).to_i
    revenue      = scope.sum(revenue_col).to_f

    unique_customers =
      scope.where.not(shopline_customer_id: nil).distinct.count(:shopline_customer_id)

    yearly_orders  = scope.group(:source_year).count
    yearly_revenue = scope.group(:source_year).sum(revenue_col) # {2024=>..., 2025=>...}

    # 常被一起買（同一個 order_number 裡的其他品項）
    copurchase_rows =
      ShoplineOrder
        .joins("INNER JOIN shopline_orders o2 ON o2.order_number = shopline_orders.order_number")
        .where(shopline_orders: { product_name: @product_name })
        .where.not(o2: { product_name: [nil, "", @product_name] })
        .group("o2.product_name")
        .order(Arel.sql("COUNT(*) DESC"))
        .limit(5)
        .count

    # Top 客戶（營收）
    top_customer_rows =
      scope
        .where.not(shopline_customer_id: nil)
        .group(:shopline_customer_id)
        .select(
          "shopline_customer_id",
          "MAX(customer_name) AS full_name",
          "MAX(email) AS email",
          "MAX(membership_level) AS membership_level",
          "COUNT(*) AS orders_count",
          "COALESCE(SUM(quantity), 0) AS units_sold",
          "COALESCE(SUM(#{revenue_col}), 0) AS revenue"
        )
        .order(Arel.sql("COALESCE(SUM(#{revenue_col}), 0) DESC, SUM(quantity) DESC"))
        .limit(10)

    top_customers = top_customer_rows.map do |r|
      {
        shopline_customer_id: r.shopline_customer_id,
        full_name: r.try(:full_name),
        email: r.try(:email),
        membership_level: r.try(:membership_level),
        orders_count: r.try(:orders_count).to_i,
        units_sold: r.try(:units_sold).to_i,
        revenue: r.try(:revenue).to_f
      }
    end

    avg_order_amount =
      orders_count > 0 ? (revenue / orders_count) : 0

    avg_units_per_order =
      orders_count > 0 ? (units_sold.to_f / orders_count) : 0

    top_cities = scope
    .where.not(city: [nil, ""])
    .group(:city)
    .order(Arel.sql("COUNT(*) DESC"))
    .limit(3)
    .count

    @analysis = OpenStruct.new(
      product_name: @product_name,
      orders_count: orders_count,
      units_sold: units_sold,
      revenue: revenue,
      unique_customers: unique_customers,
      avg_order_amount: avg_order_amount,
      avg_units_per_order: avg_units_per_order,
      first_order_at: scope.minimum(:order_date),
      last_order_at: scope.maximum(:order_date),
      yearly_orders: yearly_orders || {},
      yearly_revenue: yearly_revenue || {},
      copurchase_top: copurchase_rows || {},
      top_customers: top_customers || [],
      top_cities: top_cities,
    )
  end

  private
  def revenue_column
    ShoplineOrder.column_names.include?("checkout_amount") ? "checkout_amount" : "total_amount"
  end

  def top_products_for_year(year, q:, sort:, limit:, combo: false)
    revenue_col = revenue_column

    scope = ShoplineOrder.where(source_year: year).where.not(product_name: [nil, ""])

    if combo
      scope = scope.where(
        "product_name ~ '\\D+[0-9]+\\D+[0-9]+' OR product_name ~ '[+＋/]' OR product_name LIKE '%套組%'"
      )
    elsif q.present?
      scope = scope.where("product_name ILIKE ?", "%#{q}%")
    end

    order_sql =
      case sort
      when "revenue" then "revenue DESC"
      when "units"   then "total_quantity DESC"
      else                "orders_count DESC"
      end

    scope
      .select(
        "product_name",
        "COUNT(*) AS orders_count",
        "COALESCE(SUM(quantity), 0) AS total_quantity",
        "COALESCE(SUM(#{revenue_col}), 0) AS revenue",
        "COUNT(DISTINCT shopline_customer_id) AS unique_customers"
      )
      .group("product_name")
      .order(Arel.sql(order_sql))
      .limit(limit)
  end

  def buyer_stats(product_names, year)
    return {} if product_names.blank?

    conn = ActiveRecord::Base.connection
    quoted_names = product_names.map { |n| conn.quote(n) }.join(", ")
    quoted_year  = conn.quote(year)

    repurchase_sql = <<~SQL
      WITH order_counts AS (
        SELECT email, product_name, COUNT(*) AS cnt
        FROM shopline_orders
        WHERE source_year = #{quoted_year}
          AND product_name IN (#{quoted_names})
          AND email IS NOT NULL AND email <> ''
        GROUP BY email, product_name
      )
      SELECT product_name,
            COUNT(*) AS total_buyers,
            COUNT(CASE WHEN cnt >= 2 THEN 1 END) AS repeat_buyers
      FROM order_counts
      GROUP BY product_name
    SQL

    stats = {}

    conn.exec_query(repurchase_sql).each do |r|
      stats[r["product_name"]] = {
        buyers:        r["total_buyers"].to_i,
        repeat_buyers: r["repeat_buyers"].to_i
      }
    end

    stats
  end
end

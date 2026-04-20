# frozen_string_literal: true

class FirstPurchaseController < ApplicationController
  SERIES_OPTIONS = %w[代謝錠 全能 薑黃 膠原蛋白 美白 蝦紅素 清纖粉 魚油 私密粉 益生菌 穀胱甘肽 維DK鈣].freeze

  # 首購→第二購 已知路徑（來自資料分析）
  SECOND_PURCHASE_MAP = {
    "代謝錠" => [["代謝錠", 35.4], ["薑黃", 14.5], ["全能", 11.6], ["膠原蛋白", 7.3], ["美白", 5.4]],
    "全能"   => [["全能", 34.6], ["代謝錠", 16.0], ["美白", 9.9], ["薑黃", 6.9]],
    "薑黃"   => [["代謝錠", 31.5], ["薑黃", 22.0], ["全能", 12.6], ["膠原蛋白", 7.9]],
    "膠原蛋白" => [["代謝錠", 33.1], ["膠原蛋白", 32.3], ["全能", 5.3], ["蝦紅素", 4.2]],
    "美白"   => [["全能", 22.6], ["美白", 20.4], ["代謝錠", 16.1], ["膠原蛋白", 10.9]],
    "蝦紅素"  => [["蝦紅素", 28.8], ["代謝錠", 20.3], ["膠原蛋白", 10.2], ["全能", 8.5]],
    "清纖粉"  => [["代謝錠", 33.3], ["清纖粉", 24.4], ["薑黃", 17.8], ["私密粉", 6.7]],
  }.freeze

  RETURN_RATES = {
    "代謝錠" => 55.0,
    "全能"   => 59.1,
    "薑黃"   => 51.7,
    "膠原蛋白" => 59.6,
    "美白"   => 59.9,
    "蝦紅素"  => 45.4,
    "清纖粉"  => 45.9,
    "魚油"   => 44.7,
    "私密粉"  => 53.1,
  }.freeze

  def index
    @series_options = SERIES_OPTIONS
    @second_purchase_map = SECOND_PURCHASE_MAP
    @return_rates = RETURN_RATES
    @selected_series = params[:series].to_s.strip
    @silent_only = params[:silent_only] == "1"
    @sort = params[:sort].to_s.presence || "amount_desc"

    # 每個 email 的首購資訊（subquery）
    first_purchase_subquery = <<~SQL
      SELECT DISTINCT ON (email)
        email,
        product_name  AS first_product,
        order_date    AS first_date,
        total_amount  AS first_amount
      FROM shopline_orders
      WHERE email IS NOT NULL AND email != ''
        AND product_name IS NOT NULL AND product_name != ''
      ORDER BY email, order_date ASC
    SQL

    # 每個 email 的訂單數
    order_count_subquery = <<~SQL
      SELECT email, COUNT(DISTINCT order_number) AS purchase_count
      FROM shopline_orders
      WHERE email IS NOT NULL AND email != ''
      GROUP BY email
    SQL

    scope = ShoplineCustomer
      .joins("INNER JOIN (#{first_purchase_subquery}) fp ON fp.email = shopline_customers.email")
      .joins("LEFT JOIN (#{order_count_subquery}) oc ON oc.email = shopline_customers.email")
      .select("shopline_customers.*, fp.first_product, fp.first_date, fp.first_amount, COALESCE(oc.purchase_count, 1) AS purchase_count")

    if @selected_series.present?
      scope = scope.where("fp.first_product LIKE ?", "%#{@selected_series}%")
    end

    if @silent_only
      scope = scope.where("COALESCE(oc.purchase_count, 1) = 1")
    end

    scope = scope.reorder(Arel.sql(sort_sql(@sort)))

    @total = scope.count
    @page = [params[:page].to_i, 1].max
    @total_pages = [(@total.to_f / 50).ceil, 1].max
    @customers = scope.offset((@page - 1) * 50).limit(50)

    # 各系列統計摘要
    @series_stats = series_stats_summary
  end

  private

  def series_stats_summary
    first_purchase_subquery = <<~SQL
      SELECT DISTINCT ON (email)
        email,
        product_name AS first_product
      FROM shopline_orders
      WHERE email IS NOT NULL AND email != ''
        AND product_name IS NOT NULL AND product_name != ''
      ORDER BY email, order_date ASC
    SQL

    order_count_subquery = <<~SQL
      SELECT email, COUNT(DISTINCT order_number) AS purchase_count
      FROM shopline_orders
      WHERE email IS NOT NULL AND email != ''
      GROUP BY email
    SQL

    rows = ShoplineCustomer
      .joins("INNER JOIN (#{first_purchase_subquery}) fp ON fp.email = shopline_customers.email")
      .joins("LEFT JOIN (#{order_count_subquery}) oc ON oc.email = shopline_customers.email")
      .select("fp.first_product, COALESCE(oc.purchase_count, 1) AS purchase_count")
      .map { |r| { product: r.first_product.to_s, count: r.purchase_count.to_i } }

    SERIES_OPTIONS.filter_map do |series|
      matched = rows.select { |r| r[:product].include?(series) }
      next if matched.empty?

      total = matched.size
      silent = matched.count { |r| r[:count] == 1 }
      {
        series: series,
        total: total,
        silent: silent,
        returned: total - silent,
        return_rate: RETURN_RATES[series] || ((total - silent).to_f / total * 100).round(1)
      }
    end
  end

  def sort_sql(sort)
    case sort
    when "amount_desc"  then "shopline_customers.total_amount DESC NULLS LAST"
    when "amount_asc"   then "shopline_customers.total_amount ASC NULLS LAST"
    when "first_desc"   then "fp.first_date DESC NULLS LAST"
    when "first_asc"    then "fp.first_date ASC NULLS LAST"
    when "silent"       then "purchase_count ASC, shopline_customers.total_amount DESC NULLS LAST"
    else "shopline_customers.total_amount DESC NULLS LAST"
    end
  end
end

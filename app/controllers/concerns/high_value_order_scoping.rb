# frozen_string_literal: true

# 破8000訂單相關頁面（速覽、待追蹤名單）共用的查詢邏輯
module HighValueOrderScoping
  extend ActiveSupport::Concern

  THRESHOLD = 8_000
  LEVELS    = %w[黑卡 金卡 銀卡 白卡 一般會員].freeze
  # total_amount 是整張訂單的付款總額（同一訂單每個商品行都重複同一值，需取 MAX）；
  # checkout_amount 是逐行商品金額，只有在 total_amount 缺失時才需要 SUM 全部商品行回推訂單總額。
  ORDER_TOTAL_SQL = <<~SQL.squish.freeze
    CASE
      WHEN MAX(NULLIF(o.total_amount, 0)) IS NOT NULL THEN MAX(NULLIF(o.total_amount, 0))
      ELSE SUM(COALESCE(o.checkout_amount, 0))
    END
  SQL

  private

  def build_scope
    scope = ShoplineOrder.from("shopline_orders o")
    if @series_filter.present?
      scope = scope.where(
        "o.order_number IN (SELECT DISTINCT order_number FROM shopline_orders WHERE product_name LIKE ?)",
        "%#{@series_filter}%"
      )
    end
    scope
      .joins("LEFT JOIN shopline_customers sc ON sc.email = o.email")
      .joins("LEFT JOIN (SELECT email, MAX(purchase_count) AS purchase_count FROM customer_purchase_summaries GROUP BY email) cps ON cps.email = o.email")
      .select(
        "o.order_number AS order_num",
        "MAX(o.customer_name) AS cust_name",
        "MAX(sc.id) AS shopline_customer_id",
        "MAX(COALESCE(sc.membership_level, o.membership_level)) AS membership_level_col",
        "MAX(o.order_date) AS ord_date",
        "#{ORDER_TOTAL_SQL} AS order_total",
        "ARRAY_AGG(DISTINCT o.product_name) AS product_names_arr",
        "MAX(COALESCE(sc.instagram_account, o.instagram_account)) AS ig_account",
        "MAX(COALESCE(sc.email, o.email)) AS email_val",
        "MAX(cps.purchase_count) AS purchase_count_val"
      )
      .where("o.payment_status = '已付款'")
      .group("o.order_number")
      .having("#{ORDER_TOTAL_SQL} >= ?", THRESHOLD)
      .order(Arel.sql("#{ORDER_TOTAL_SQL} DESC"))
  end

  def apply_period(scope)
    if @start_date.present?
      return scope.where("o.order_date >= ? AND o.order_date <= ?", @start_date.beginning_of_day, @end_date.end_of_day)
    end

    cutoff = case @period
             when 'yesterday' then Date.yesterday.beginning_of_day
             when 'week'      then 1.week.ago.beginning_of_day
             when 'month'     then 1.month.ago.beginning_of_day
             end
    return scope unless cutoff
    @period == 'yesterday' ? scope.where("o.order_date >= ? AND o.order_date < ?", cutoff, Date.today.beginning_of_day) : scope.where("o.order_date >= ?", cutoff)
  end

  def parse_date(value)
    Date.parse(value) if value.present?
  rescue ArgumentError
    nil
  end

  def product_series(name)
    name.to_s.match(/\A([^\d]+)/)&.captures&.first&.strip.presence || name.to_s
  end

  # 針對每張訂單的每個商品，找出該客人「這個系列」在這張訂單之前最早的購買日期，
  # 以及這張訂單之後有沒有再買過同系列（repurchased_later，給「這個首購產品後來有沒有回購」判斷用）
  def build_products_by_order(orders)
    emails = orders.map(&:email_val).compact.uniq
    raw_history = ShoplineOrder.where(email: emails).where("payment_status = '已付款'").pluck(:email, :product_name, :order_date)
    series_dates = Hash.new { |h, k| h[k] = [] }
    raw_history.each { |email, name, date| series_dates[[email, product_series(name)]] << date }
    series_dates.each_value(&:sort!)

    orders.each_with_object({}) do |o, result|
      result[o.order_num] = Array(o.product_names_arr).compact.map do |name|
        dates = series_dates[[o.email_val, product_series(name)]] || []
        prior_date = dates.find { |d| d < o.ord_date }
        repurchased_later = dates.any? { |d| d > o.ord_date }
        { name: name, prior_date: prior_date, repurchased_later: repurchased_later }
      end
    end
  end

  # 舊客定義：卡別在 LEVELS 內；一般會員需購買次數 ≠ 1 才算舊客
  def select_old_orders(orders)
    orders.select do |o|
      next false unless LEVELS.include?(o.membership_level_col)
      o.membership_level_col == '一般會員' ? o.purchase_count_val.to_i != 1 : true
    end
  end
end

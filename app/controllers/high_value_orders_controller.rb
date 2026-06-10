class HighValueOrdersController < ApplicationController
  THRESHOLD = 10_000
  LEVELS    = %w[黑卡 金卡 銀卡 白卡 一般會員].freeze

  def index
    @period = params[:period].presence || 'month'
    @level  = params[:level].presence
    @levels = LEVELS

    scope = build_scope
    scope = apply_period(scope)
    scope = scope.having("MAX(COALESCE(sc.membership_level, o.membership_level)) = ?", @level) if @level.present?

    @orders        = scope.to_a
    @grouped       = LEVELS.index_with { |lvl| @orders.select { |o| o.membership_level_col == lvl } }
    @total_revenue = @orders.sum { |o| o.order_total.to_f }
    @total_count   = @orders.size
  end

  private

  def build_scope
    ShoplineOrder
      .from("shopline_orders o")
      .joins("LEFT JOIN shopline_customers sc ON sc.email = o.email")
      .select(
        "o.order_number AS order_num",
        "MAX(o.customer_name) AS cust_name",
        "MAX(COALESCE(sc.membership_level, o.membership_level)) AS membership_level_col",
        "MAX(o.order_date) AS ord_date",
        "COALESCE(MAX(o.checkout_amount), SUM(o.total_amount)) AS order_total",
        "STRING_AGG(o.product_name || ' ×' || o.quantity::text, '、' ORDER BY o.product_name) AS products_list",
        "MAX(COALESCE(sc.instagram_account, o.instagram_account)) AS ig_account"
      )
      .where("o.payment_status = '已付款'")
      .group("o.order_number")
      .having("COALESCE(MAX(o.checkout_amount), SUM(o.total_amount)) >= ?", THRESHOLD)
      .order(Arel.sql("MAX(o.order_date) DESC"))
  end

  def apply_period(scope)
    cutoff = case @period
             when 'today' then Date.today.beginning_of_day
             when 'week'  then 1.week.ago.beginning_of_day
             when 'month' then 1.month.ago.beginning_of_day
             end
    cutoff ? scope.where("o.order_date >= ?", cutoff) : scope
  end
end

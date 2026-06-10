class HighValueOrdersController < ApplicationController
  THRESHOLD = 10_000
  LEVELS    = %w[黑卡 金卡 銀卡 白卡 一般會員].freeze
  ALL_TABS  = (LEVELS + ['新客']).freeze

  def index
    @period = params[:period].presence || 'month'
    @level  = params[:level].presence || LEVELS.first
    @levels = ALL_TABS

    scope = build_scope
    scope = apply_period(scope)

    if @level == '新客'
      scope = scope.having("MAX(cps.purchase_count) = 1")
    else
      scope = scope.having("MAX(COALESCE(sc.membership_level, o.membership_level)) = ?", @level)
    end

    @orders        = scope.to_a
    @grouped       = ALL_TABS.index_with { |lvl| @orders.select { |o| lvl == '新客' ? true : o.membership_level_col == lvl } }
    @total_revenue = @orders.sum { |o| o.order_total.to_f }
    @total_count   = @orders.size
  end

  private

  def build_scope
    ShoplineOrder
      .from("shopline_orders o")
      .joins("LEFT JOIN shopline_customers sc ON sc.email = o.email")
      .joins("LEFT JOIN customer_purchase_summaries cps ON cps.email = o.email")
      .select(
        "o.order_number AS order_num",
        "MAX(o.customer_name) AS cust_name",
        "MAX(COALESCE(sc.membership_level, o.membership_level)) AS membership_level_col",
        "MAX(o.order_date) AS ord_date",
        "COALESCE(MAX(o.checkout_amount), SUM(o.total_amount)) AS order_total",
        "STRING_AGG(o.product_name || ' ×' || o.quantity::text, '、' ORDER BY o.product_name) AS products_list",
        "MAX(COALESCE(sc.instagram_account, o.instagram_account)) AS ig_account",
        "MAX(cps.purchase_count) AS purchase_count_val"
      )
      .where("o.payment_status = '已付款'")
      .group("o.order_number")
      .having("COALESCE(MAX(o.checkout_amount), SUM(o.total_amount)) >= ?", THRESHOLD)
      .order(Arel.sql("MAX(o.order_date) DESC"))
  end

  def apply_period(scope)
    cutoff = case @period
             when 'yesterday' then Date.yesterday.beginning_of_day
             when 'week'      then 1.week.ago.beginning_of_day
             when 'month'     then 1.month.ago.beginning_of_day
             end
    return scope unless cutoff
    @period == 'yesterday' ? scope.where("o.order_date >= ? AND o.order_date < ?", cutoff, Date.today.beginning_of_day) : scope.where("o.order_date >= ?", cutoff)
  end
end

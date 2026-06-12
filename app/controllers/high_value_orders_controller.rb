class HighValueOrdersController < ApplicationController
  THRESHOLD      = 10_000
  LEVELS         = %w[黑卡 金卡 銀卡 白卡 一般會員].freeze
  ALL_TABS       = (LEVELS + ['新客']).freeze
  SERIES_OPTIONS = %w[代謝錠 全能 薑黃 膠原蛋白 美白 蝦紅素 清纖粉 魚油 私密粉 益生菌 穀胱甘肽 維DK鈣 面膜].freeze

  def index
    @period         = params[:period].presence || 'month'
    @level          = params[:level].presence || LEVELS.first
    @levels         = ALL_TABS
    @series_filter  = params[:series_filter].presence
    @specific_month = params[:specific_month].presence

    base = apply_period(build_scope)

    # 各 tab 計數：只撈最精簡欄位，不帶 level filter
    count_base = ShoplineOrder.from("shopline_orders o")
    if @series_filter.present?
      count_base = count_base.where(
        "o.order_number IN (SELECT DISTINCT order_number FROM shopline_orders WHERE product_name LIKE ?)",
        "%#{@series_filter}%"
      )
    end
    all_for_counts = apply_period(
      count_base
        .joins("LEFT JOIN shopline_customers sc ON sc.email = o.email")
        .joins("LEFT JOIN (SELECT email, MAX(purchase_count) AS purchase_count FROM customer_purchase_summaries GROUP BY email) cps ON cps.email = o.email")
        .select(
          "MAX(COALESCE(sc.membership_level, o.membership_level)) AS membership_level_col",
          "MAX(cps.purchase_count) AS purchase_count_val"
        )
        .where("o.payment_status = '已付款'")
        .group("o.order_number")
        .having("MAX(o.total_amount) >= ?", THRESHOLD)
    ).to_a
    @tab_counts = LEVELS.index_with { |lvl| all_for_counts.count { |o| o.membership_level_col == lvl } }
    @tab_counts['新客'] = all_for_counts.count { |o| o.purchase_count_val.to_i == 1 }

    # 目前選中 tab 的完整資料
    scope = base
    if @level == '新客'
      scope = scope.having("MAX(cps.purchase_count) = 1")
    else
      scope = scope.having("MAX(COALESCE(sc.membership_level, o.membership_level)) = ?", @level)
    end

    @orders        = scope.to_a
    @grouped       = ALL_TABS.index_with { |lvl| @orders.select { |o| lvl == '新客' ? true : o.membership_level_col == lvl } }
    @total_revenue = @orders.sum { |o| o.order_total.to_f }
    @total_count   = @orders.size

    order_nums = @orders.map(&:order_num)
    @gift_records = OrderGiftRecord.where(order_number: order_nums).index_by(&:order_number)
  end

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
        "MAX(COALESCE(sc.membership_level, o.membership_level)) AS membership_level_col",
        "MAX(o.order_date) AS ord_date",
        "MAX(o.total_amount) AS order_total",
        "STRING_AGG(DISTINCT o.product_name || ' ×' || o.quantity::text, '、' ORDER BY o.product_name || ' ×' || o.quantity::text) AS products_list",
        "MAX(COALESCE(sc.instagram_account, o.instagram_account)) AS ig_account",
        "MAX(COALESCE(sc.email, o.email)) AS email_val",
        "MAX(cps.purchase_count) AS purchase_count_val"
      )
      .where("o.payment_status = '已付款'")
      .group("o.order_number")
      .having("MAX(o.total_amount) >= ?", THRESHOLD)
      .order(Arel.sql("MAX(o.order_date) DESC"))
  end

  def apply_period(scope)
    if @specific_month.present?
      begin
        d = Date.parse("#{@specific_month}-01")
        return scope.where("o.order_date >= ? AND o.order_date < ?", d.beginning_of_month, d.next_month.beginning_of_month)
      rescue ArgumentError
        return scope
      end
    end
    cutoff = case @period
             when 'yesterday' then Date.yesterday.beginning_of_day
             when 'week'      then 1.week.ago.beginning_of_day
             when 'month'     then 1.month.ago.beginning_of_day
             end
    return scope unless cutoff
    @period == 'yesterday' ? scope.where("o.order_date >= ? AND o.order_date < ?", cutoff, Date.today.beginning_of_day) : scope.where("o.order_date >= ?", cutoff)
  end
end

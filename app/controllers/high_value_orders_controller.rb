class HighValueOrdersController < ApplicationController
  THRESHOLD      = 8_000
  LEVELS         = %w[黑卡 金卡 銀卡 白卡 一般會員].freeze
  # total_amount 是整張訂單的付款總額（同一訂單每個商品行都重複同一值，需取 MAX）；
  # checkout_amount 是逐行商品金額，只有在 total_amount 缺失時才需要 SUM 全部商品行回推訂單總額。
  ORDER_TOTAL_SQL = <<~SQL.squish.freeze
    CASE
      WHEN MAX(NULLIF(o.total_amount, 0)) IS NOT NULL THEN MAX(NULLIF(o.total_amount, 0))
      ELSE SUM(COALESCE(o.checkout_amount, 0))
    END
  SQL

  def index
    @series_options = CrmProduct.series_labels_for_filter
    @period         = params[:period].presence || 'month'
    @tab            = %w[new old].include?(params[:tab]) ? params[:tab] : 'old'
    @series_filter  = params[:series_filter].presence
    @start_date     = parse_date(params[:start_date])
    @end_date       = parse_date(params[:end_date]) || @start_date
    @end_date       = @start_date if @start_date && @end_date && @end_date < @start_date

    all_orders = apply_period(build_scope).to_a

    new_orders = all_orders.select { |o| o.purchase_count_val.to_i == 1 }
    old_orders = all_orders.select do |o|
      next false unless LEVELS.include?(o.membership_level_col)
      o.membership_level_col == '一般會員' ? o.purchase_count_val.to_i != 1 : true
    end

    @new_count  = new_orders.size
    @old_count  = old_orders.size
    @tab_counts = LEVELS.index_with { |lvl| old_orders.count { |o| o.membership_level_col == lvl } }

    @groups = @tab == 'new' ? [["新客", new_orders]] : LEVELS.map { |lvl| [lvl, old_orders.select { |o| o.membership_level_col == lvl }] }

    visible_orders = @groups.flat_map { |_, rows| rows }
    order_nums = visible_orders.map(&:order_num)
    @gift_records = OrderGiftRecord.where(order_number: order_nums).index_by(&:order_number)

    customer_ids = visible_orders.map(&:shopline_customer_id).compact
    @profiles_by_customer_id = CustomerProfile.where(shopline_customer_id: customer_ids).index_by(&:shopline_customer_id)

    if @tab == 'new'
      @health_missing_count = new_orders.count do |o|
        profile = @profiles_by_customer_id[o.shopline_customer_id]
        profile&.health_profile.blank? && profile&.health_tags.blank?
      end
    else
      @old_health_missing_count = old_orders.count do |o|
        profile = @profiles_by_customer_id[o.shopline_customer_id]
        profile&.health_profile.blank? && profile&.health_tags.blank?
      end
    end
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
        "MAX(sc.id) AS shopline_customer_id",
        "MAX(COALESCE(sc.membership_level, o.membership_level)) AS membership_level_col",
        "MAX(o.order_date) AS ord_date",
        "#{ORDER_TOTAL_SQL} AS order_total",
        "STRING_AGG(DISTINCT o.product_name || ' ×' || o.quantity::text, '、' ORDER BY o.product_name || ' ×' || o.quantity::text) AS products_list",
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
end

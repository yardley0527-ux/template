# frozen_string_literal: true

# 黑金卡消費備註：讓老闆一眼看到本日／本週／本月回來消費的黑卡、金卡客人，
# 並可直接在頁面上記備註（誰要特別關注、聯繫過什麼）
class BlackGoldCustomersController < ApplicationController
  LEVELS = %w[黑卡 金卡].freeze

  ORDER_TOTAL_SQL = <<~SQL.squish.freeze
    CASE
      WHEN MAX(NULLIF(o.total_amount, 0)) IS NOT NULL THEN MAX(NULLIF(o.total_amount, 0))
      ELSE SUM(COALESCE(o.checkout_amount, 0))
    END
  SQL

  Row = Struct.new(
    :shopline_customer_id, :full_name, :email, :ig_account, :membership_level,
    :orders, :period_total, :latest_date, :profile,
    keyword_init: true
  )

  PERIODS = %w[today week month].freeze

  def index
    @period = PERIODS.include?(params[:period]) ? params[:period] : "today"

    @counts = PERIODS.index_with { |p| build_rows(p).size }
    @groups = LEVELS.map { |level| [level, build_rows(@period).select { |r| r.membership_level == level }] }
  end

  def upsert_note
    customer = ShoplineCustomer.find(params[:customer_id])
    profile  = customer.customer_profile || customer.build_customer_profile
    note     = params[:note].to_s
    profile.update!(
      black_gold_note: note,
      black_gold_note_edited_by: note.present? ? current_user.username : nil
    )

    head :ok
  end

  private

  def period_range(period)
    case period
    when "today" then Time.zone.today.beginning_of_day..Time.zone.today.end_of_day
    when "week"  then Time.zone.today.beginning_of_week.beginning_of_day..Time.zone.today.end_of_day
    else              Time.zone.today.beginning_of_month.beginning_of_day..Time.zone.today.end_of_day
    end
  end

  def build_rows(period)
    range = period_range(period)

    orders = ShoplineOrder.from("shopline_orders o")
      .joins("INNER JOIN shopline_customers sc ON sc.email = o.email")
      .where("sc.membership_level IN (?)", LEVELS)
      .where("o.payment_status = '已付款'")
      .where("o.order_date >= ? AND o.order_date <= ?", range.first, range.last)
      .select(
        "o.order_number AS order_num",
        "MAX(o.customer_name) AS cust_name",
        "MAX(sc.id) AS shopline_customer_id",
        "MAX(sc.email) AS email_val",
        "MAX(sc.membership_level) AS membership_level_col",
        "MAX(sc.instagram_account) AS ig_account",
        "MAX(o.order_date) AS ord_date",
        "#{ORDER_TOTAL_SQL} AS order_total",
        "STRING_AGG(DISTINCT o.product_name, '、' ORDER BY o.product_name) AS products_list"
      )
      .group("o.order_number")
      .to_a

    customer_ids = orders.map(&:shopline_customer_id).compact.uniq
    profiles_by_customer_id = CustomerProfile.where(shopline_customer_id: customer_ids).index_by(&:shopline_customer_id)

    orders.group_by(&:shopline_customer_id).map do |customer_id, os|
      first = os.first
      sorted = os.sort_by(&:ord_date).reverse
      Row.new(
        shopline_customer_id: customer_id,
        full_name:            first.cust_name,
        email:                first.email_val,
        ig_account:           first.ig_account,
        membership_level:     first.membership_level_col,
        orders:               sorted,
        period_total:         os.sum { |o| o.order_total.to_f },
        latest_date:          sorted.first.ord_date,
        profile:              profiles_by_customer_id[customer_id]
      )
    end.sort_by { |r| -r.latest_date.to_i }
  end
end

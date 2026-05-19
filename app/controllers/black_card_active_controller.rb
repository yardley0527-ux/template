# frozen_string_literal: true

class BlackCardActiveController < ApplicationController
  PER_PAGE = 20

  def index
    @year  = Date.current.year
    @sort  = params[:sort].to_s.presence || "amount_desc"
    @page  = [params[:page].to_i, 1].max

    year_start = Date.new(@year, 1, 1).beginning_of_day
    year_end   = Date.new(@year, 12, 31).end_of_day

    base = ShoplineCustomer
      .where(membership_level: "黑卡")
      .joins(:shopline_orders)
      .where(shopline_orders: { order_date: year_start..year_end })
      .group("shopline_customers.id")

    @total       = base.count.size
    @total_pages = [(@total.to_f / PER_PAGE).ceil, 1].max

    @customers = base
      .select(<<~SQL.squish)
        shopline_customers.*,
        COUNT(shopline_orders.id)                                        AS year_order_count,
        SUM(COALESCE(shopline_orders.checkout_amount,
                     shopline_orders.total_amount))                      AS year_total_amount,
        MAX(shopline_orders.order_date)                                  AS year_last_order_date
      SQL
      .reorder(Arel.sql(sort_sql(@sort)))
      .offset((@page - 1) * PER_PAGE)
      .limit(PER_PAGE)
  end

  private

  def sort_sql(sort)
    case sort
    when "amount_desc"  then "year_total_amount DESC NULLS LAST"
    when "amount_asc"   then "year_total_amount ASC NULLS LAST"
    when "count_desc"   then "year_order_count DESC"
    when "last_desc"    then "year_last_order_date DESC NULLS LAST"
    when "expiry_asc"   then "shopline_customers.membership_expiry_date ASC NULLS LAST"
    when "expiry_desc"  then "shopline_customers.membership_expiry_date DESC NULLS LAST"
    else "year_total_amount DESC NULLS LAST"
    end
  end
end

# frozen_string_literal: true

class InactiveMembersController < ApplicationController
  CARD_LEVELS  = %w[黑卡 金卡 銀卡].freeze
  DAYS_OPTIONS = [30, 60, 90, 180].freeze
  PER_PAGE     = 20

  def index
    @days           = DAYS_OPTIONS.include?(params[:days].to_i) ? params[:days].to_i : 90
    @selected_level = CARD_LEVELS.include?(params[:level].to_s) ? params[:level].to_s : CARD_LEVELS.first
    @sort           = params[:sort].to_s.presence || "days_desc"
    @page           = [params[:page].to_i, 1].max

    cutoff = @days.days.ago

    @tier_counts = CARD_LEVELS.index_with do |level|
      inactive_scope(level, cutoff).count
    end

    base         = inactive_scope(@selected_level, cutoff)
    @total       = base.count
    @total_pages = [(@total.to_f / PER_PAGE).ceil, 1].max

    @customers = base
      .select(<<~SQL.squish)
        shopline_customers.*,
        cps.last_order_date,
        cps.purchase_count,
        EXTRACT(EPOCH FROM (NOW() - cps.last_order_date)) / 86400 AS days_since_last
      SQL
      .reorder(Arel.sql(sort_sql(@sort)))
      .offset((@page - 1) * PER_PAGE)
      .limit(PER_PAGE)
  end

  private

  def inactive_scope(level, cutoff)
    ShoplineCustomer
      .where(membership_level: level)
      .joins("LEFT JOIN customer_purchase_summaries cps ON cps.email = shopline_customers.email")
      .where("cps.last_order_date IS NULL OR cps.last_order_date < ?", cutoff)
  end

  def sort_sql(sort)
    case sort
    when "days_desc"   then "cps.last_order_date ASC NULLS FIRST"
    when "days_asc"    then "cps.last_order_date DESC NULLS LAST"
    when "expiry_asc"  then "shopline_customers.membership_expiry_date ASC NULLS LAST"
    when "expiry_desc" then "shopline_customers.membership_expiry_date DESC NULLS LAST"
    else "cps.last_order_date ASC NULLS FIRST"
    end
  end
end

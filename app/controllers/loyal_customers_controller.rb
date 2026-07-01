# app/controllers/loyal_customers_controller.rb
# frozen_string_literal: true

class LoyalCustomersController < ApplicationController
  TIERS = %w[鐵粉 忠實客 回購客].freeze
  PER_PAGE = 20

  def index
    @series_options  = CrmProduct.series_labels_for_filter
    @selected_series = params[:series].to_s.strip.presence || @series_options.first
    @selected_tier   = params[:tier].to_s.strip.presence
    @sort            = params[:sort].to_s.presence || "total_desc"
    @page            = [params[:page].to_i, 1].max

    @series_stats = Rails.cache.fetch("loyal_customers:series_stats:v1", expires_in: 30.minutes) do
      series_stats_summary
    end

    base_scope = CustomerSeriesLoyalty
      .joins("INNER JOIN shopline_customers sc ON sc.email = customer_series_loyalties.email")
      .where(series: @selected_series)

    base_scope = base_scope.where(tier: @selected_tier) if @selected_tier.present?

    @total       = base_scope.count
    @total_pages = [(@total.to_f / PER_PAGE).ceil, 1].max

    @customers = base_scope
      .select(<<~SQL.squish)
        customer_series_loyalties.*,
        sc.id         AS customer_id,
        sc.full_name,
        sc.membership_level,
        sc.instagram_account,
        sc.mobile_phone
      SQL
      .reorder(Arel.sql(sort_sql(@sort)))
      .offset((@page - 1) * PER_PAGE)
      .limit(PER_PAGE)

    @tier_counts = CustomerSeriesLoyalty
      .where(series: @selected_series)
      .group(:tier)
      .count
  end

  private

  def series_stats_summary
    rows = CustomerSeriesLoyalty
      .group(:series)
      .pluck(
        :series,
        Arel.sql("COUNT(*)"),
        Arel.sql("SUM(CASE WHEN tier = '鐵粉'  THEN 1 ELSE 0 END)"),
        Arel.sql("SUM(CASE WHEN tier = '忠實客' THEN 1 ELSE 0 END)"),
        Arel.sql("SUM(CASE WHEN tier = '回購客' THEN 1 ELSE 0 END)"),
        Arel.sql("AVG(order_count)::numeric(10,1)")
      )

    rows.map do |series, total, iron, loyal, repurchase, avg|
      {
        series:     series,
        total:      total.to_i,
        iron:       iron.to_i,
        loyal:      loyal.to_i,
        repurchase: repurchase.to_i,
        avg_count:  avg.to_f.round(1)
      }
    end.sort_by { |h| @series_options.index(h[:series]) || 999 }
  end

  def sort_sql(sort)
    case sort
    when "total_desc"  then "customer_series_loyalties.total_amount DESC NULLS LAST"
    when "total_asc"   then "customer_series_loyalties.total_amount ASC NULLS LAST"
    when "count_desc"  then "customer_series_loyalties.order_count DESC"
    when "last_desc"   then "customer_series_loyalties.last_date DESC NULLS LAST"
    when "last_asc"    then "customer_series_loyalties.last_date ASC NULLS LAST"
    else "customer_series_loyalties.total_amount DESC NULLS LAST"
    end
  end
end
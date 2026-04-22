# frozen_string_literal: true

class HighSpenderFirstPurchaseController < ApplicationController
  THRESHOLD = 10_000
  PER_PAGE  = 50

  def index
    @page = [params[:page].to_i, 1].max
    @selected_year   = params[:year].to_s.presence
    @selected_series = params[:series].to_s.strip.presence
    @repurchase_only = params[:repurchase_only] == "1"
    @sort = params[:sort].to_s.presence || "first_date_desc"

    analytics = HighSpenderFirstPurchaseAnalytics.new(
      threshold: THRESHOLD,
      year: @selected_year,
      series: @selected_series,
      repurchase_only: @repurchase_only
    )

    @summary_cards      = analytics.summary_cards
    @year_stats         = analytics.year_stats
    @monthly_stats      = analytics.monthly_stats
    @series_stats       = analytics.series_stats
    @second_purchase_map = analytics.second_purchase_map
    @series_options     = analytics.series_options

    scoped_customers = analytics.customer_scope
      .reorder(Arel.sql(sort_sql(@sort)))

    @total = scoped_customers.count
    @total_pages = [(@total.to_f / PER_PAGE).ceil, 1].max
    @customers = scoped_customers.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
  end

  private

  def sort_sql(sort)
    case sort
    when "first_amount_desc"
      "customer_purchase_summaries.first_amount DESC NULLS LAST"
    when "first_amount_asc"
      "customer_purchase_summaries.first_amount ASC NULLS LAST"
    when "first_date_asc"
      "customer_purchase_summaries.first_date ASC NULLS LAST"
    when "repurchase"
      "customer_purchase_summaries.purchase_count DESC, customer_purchase_summaries.first_amount DESC NULLS LAST"
    else
      "customer_purchase_summaries.first_date DESC NULLS LAST"
    end
  end
end
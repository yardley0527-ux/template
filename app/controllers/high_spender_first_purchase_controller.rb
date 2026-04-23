class HighSpenderFirstPurchaseController < ApplicationController
  THRESHOLD = 10_000

  def index
    @selected_year   = params[:year].to_s.presence
    @selected_series = params[:series].to_s.strip.presence
    @repurchase_only = params[:repurchase_only] == "1"
    @view_mode       = params[:view]

    analytics = HighSpenderFirstPurchaseAnalytics.new(
      threshold:       THRESHOLD,
      year:            @selected_year,
      series:          @selected_series,
      repurchase_only: @repurchase_only
    )

    @summary_cards       = analytics.summary_cards
    @year_stats          = analytics.year_stats
    @monthly_stats       = analytics.monthly_stats
    @monthly_series_map  = analytics.monthly_series_breakdown
    @series_stats        = analytics.series_stats
    @second_purchase_map = analytics.second_purchase_map
    @series_options      = analytics.series_options

    @customers = []

    if @view_mode == "customers" && @selected_series.present?
      scope = CustomerPurchaseSummary
        .where("first_amount >= ?", THRESHOLD)
        .where(first_series: @selected_series)

      if @selected_year.present?
        scope = scope.where("EXTRACT(YEAR FROM first_date) = ?", @selected_year.to_i)
      end

      @customers = scope
        .joins("LEFT JOIN shopline_customers sc ON LOWER(TRIM(sc.email)) = LOWER(TRIM(customer_purchase_summaries.email))")
        .select(
          "customer_purchase_summaries.*",
          "sc.id AS shopline_customer_id",
          "sc.full_name AS customer_name",
          "sc.instagram_account AS instagram_account"
        )
        .order(Arel.sql("CASE WHEN customer_purchase_summaries.purchase_count >= 2 THEN 0 ELSE 1 END"))
        .order(first_date: :desc)
    end
  end
end
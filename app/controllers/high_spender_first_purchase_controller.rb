class HighSpenderFirstPurchaseController < ApplicationController
  THRESHOLD = 10_000

  def index
    @selected_year   = params[:year].to_s.presence
    @selected_series = params[:series].to_s.strip.presence
    @repurchase_only = params[:repurchase_only] == "1"

    analytics = HighSpenderFirstPurchaseAnalytics.new(
      threshold:       THRESHOLD,
      year:            @selected_year,
      series:          @selected_series,
      repurchase_only: @repurchase_only
    )

    @summary_cards          = analytics.summary_cards
    @year_stats             = analytics.year_stats
    @monthly_stats          = analytics.monthly_stats
    @monthly_series_map     = analytics.monthly_series_breakdown  # 新增
    @series_stats           = analytics.series_stats
    @second_purchase_map    = analytics.second_purchase_map
    @series_options         = analytics.series_options
  end


end
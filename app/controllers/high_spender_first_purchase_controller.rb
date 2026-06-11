class HighSpenderFirstPurchaseController < ApplicationController
  THRESHOLD = 10_000

  def index
    @selected_year   = params[:year].to_s.presence || Date.today.year.to_s
    @selected_series = params[:series].to_s.strip.presence
    @repurchase_only = params[:repurchase_only] == "1"

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

    scope = CustomerPurchaseSummary
      .where("first_amount >= ?", THRESHOLD)
      .where("EXTRACT(YEAR FROM first_date) = ?", @selected_year.to_i)

    scope = scope.where(first_series: @selected_series) if @selected_series.present?
    scope = scope.where("purchase_count >= 2") if @repurchase_only

    @customers = scope
      .joins("LEFT JOIN shopline_customers sc ON LOWER(TRIM(sc.email)) = LOWER(TRIM(customer_purchase_summaries.email))")
      .select(
        "customer_purchase_summaries.*",
        "sc.id AS shopline_customer_id",
        "sc.full_name AS customer_name",
        "sc.instagram_account AS instagram_account"
      )
      .order(Arel.sql("CASE WHEN customer_purchase_summaries.purchase_count >= 2 THEN 1 ELSE 0 END, customer_purchase_summaries.first_date ASC"))

    @last_snapshot_week = CustomerPurchaseSummary.where.not(follow_up_week: nil).maximum(:follow_up_week)
  end

  def snapshot
    monday = WeeklyFollowUpSnapshotService.call
    redirect_to high_spender_first_purchase_path, notice: "本週跟進名單已更新（#{monday.strftime('%Y-%m-%d')} 起）"
  end

  def update_field
    record = CustomerPurchaseSummary.find_by!(identity_key: params[:identity_key])
    field  = params[:field]

    case field
    when "line_bound"
      record.update!(line_bound: params[:value] == "1")
    when "follow_up_product"
      record.update!(follow_up_product: params[:value].presence)
    end

    head :ok
  end
end

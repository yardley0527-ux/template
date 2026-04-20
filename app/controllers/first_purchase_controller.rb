# app/controllers/first_purchase_controller.rb
# frozen_string_literal: true

class FirstPurchaseController < ApplicationController
  SERIES_OPTIONS = %w[代謝錠 全能 薑黃 膠原蛋白 美白 蝦紅素 清纖粉 魚油 私密粉 益生菌 穀胱甘肽 維DK鈣].freeze

  SECOND_PURCHASE_MAP = {
    "代謝錠" => [["代謝錠", 35.4], ["薑黃", 14.5], ["全能", 11.6], ["膠原蛋白", 7.3], ["美白", 5.4]],
    "全能"   => [["全能", 34.6], ["代謝錠", 16.0], ["美白", 9.9], ["薑黃", 6.9]],
    "薑黃"   => [["代謝錠", 31.5], ["薑黃", 22.0], ["全能", 12.6], ["膠原蛋白", 7.9]],
    "膠原蛋白" => [["代謝錠", 33.1], ["膠原蛋白", 32.3], ["全能", 5.3], ["蝦紅素", 4.2]],
    "美白"   => [["全能", 22.6], ["美白", 20.4], ["代謝錠", 16.1], ["膠原蛋白", 10.9]],
    "蝦紅素"  => [["蝦紅素", 28.8], ["代謝錠", 20.3], ["膠原蛋白", 10.2], ["全能", 8.5]],
    "清纖粉"  => [["代謝錠", 33.3], ["清纖粉", 24.4], ["薑黃", 17.8], ["私密粉", 6.7]],
  }.freeze

  RETURN_RATES = {
    "代謝錠" => 55.0,
    "全能"   => 59.1,
    "薑黃"   => 51.7,
    "膠原蛋白" => 59.6,
    "美白"   => 59.9,
    "蝦紅素"  => 45.4,
    "清纖粉"  => 45.9,
    "魚油"   => 44.7,
    "私密粉"  => 53.1,
  }.freeze

  PER_PAGE = 50

  def index
    @series_options = SERIES_OPTIONS
    @second_purchase_map = SECOND_PURCHASE_MAP
    @return_rates = RETURN_RATES
    @selected_series = params[:series].to_s.strip
    @silent_only = params[:silent_only] == "1"
    @sort = params[:sort].to_s.presence || "amount_desc"
    @page = [params[:page].to_i, 1].max

    base_scope = ShoplineCustomer
      .joins("INNER JOIN customer_purchase_summaries cps ON cps.email = shopline_customers.email")

    base_scope = base_scope.where("cps.first_series = ?", @selected_series) if @selected_series.present?
    base_scope = base_scope.where("cps.silent_only = TRUE") if @silent_only

    @total = Rails.cache.fetch(total_cache_key, expires_in: 10.minutes) do
      base_scope.distinct.count(:id)
    end

    scope = base_scope
      .select(<<~SQL.squish)
        shopline_customers.*,
        cps.first_product,
        cps.first_series,
        cps.first_date,
        cps.first_amount,
        cps.purchase_count
      SQL
      .reorder(Arel.sql(sort_sql(@sort)))

    @total_pages = [(@total.to_f / PER_PAGE).ceil, 1].max
    @customers = scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)

    @series_stats = Rails.cache.fetch("first_purchase:series_stats:v1", expires_in: 30.minutes) do
      series_stats_summary
    end
  end

  private

  def total_cache_key
    [
      "first_purchase:total:v1",
      @selected_series.presence || "all",
      @silent_only ? "silent" : "all_status"
    ].join(":")
  end

  def series_stats_summary
    rows = CustomerPurchaseSummary
      .where.not(first_series: nil)
      .group(:first_series)
      .pluck(
        :first_series,
        Arel.sql("COUNT(*)"),
        Arel.sql("SUM(CASE WHEN silent_only = TRUE THEN 1 ELSE 0 END)")
      )

    rows.map do |series, total, silent|
      total = total.to_i
      silent = silent.to_i

      {
        series: series,
        total: total,
        silent: silent,
        returned: total - silent,
        return_rate: RETURN_RATES[series] || (total.zero? ? 0 : ((total - silent).to_f / total * 100).round(1))
      }
    end.sort_by { |h| -h[:total] }
  end

  def sort_sql(sort)
    case sort
    when "amount_desc"
      "shopline_customers.total_amount DESC NULLS LAST"
    when "amount_asc"
      "shopline_customers.total_amount ASC NULLS LAST"
    when "first_desc"
      "cps.first_date DESC NULLS LAST"
    when "first_asc"
      "cps.first_date ASC NULLS LAST"
    when "silent"
      "cps.purchase_count ASC, shopline_customers.total_amount DESC NULLS LAST"
    else
      "shopline_customers.total_amount DESC NULLS LAST"
    end
  end
end
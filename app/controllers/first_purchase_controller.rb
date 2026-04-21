# frozen_string_literal: true

class FirstPurchaseController < ApplicationController
  SERIES_OPTIONS = %w[
    代謝錠 全能 薑黃 膠原蛋白 美白 蝦紅素 清纖粉 魚油 私密粉 益生菌 穀胱甘肽 維DK鈣
  ].freeze

  PER_PAGE = 50

  def index
    @series_options = SERIES_OPTIONS
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
        cps.first_order_number,
        cps.first_product,
        cps.first_series,
        cps.first_date,
        cps.first_amount,
        cps.second_order_number,
        cps.second_product,
        cps.second_series,
        cps.second_date,
        cps.purchase_count,
        cps.silent_only,
        cps.last_order_date,
        cps.silent_days_threshold
      SQL
      .reorder(Arel.sql(sort_sql(@sort)))

    @total_pages = [(@total.to_f / PER_PAGE).ceil, 1].max
    @customers = scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)

    @series_stats = Rails.cache.fetch("first_purchase:series_stats:v2", expires_in: 30.minutes) do
      series_stats_summary
    end

    @second_purchase_map = Rails.cache.fetch("first_purchase:second_purchase_map:v2", expires_in: 30.minutes) do
      dynamic_second_purchase_map
    end
  end

  private

  def total_cache_key
    [
      "first_purchase:total:v2",
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
        Arel.sql("SUM(CASE WHEN purchase_count > 1 THEN 1 ELSE 0 END)"),
        Arel.sql("SUM(CASE WHEN silent_only = TRUE THEN 1 ELSE 0 END)")
      )

    rows.map do |series, total, returned, silent|
      total = total.to_i
      returned = returned.to_i
      silent = silent.to_i

      {
        series: series,
        total: total,
        silent: silent,
        returned: returned,
        return_rate: total.zero? ? 0 : ((returned.to_f / total) * 100).round(1)
      }
    end.sort_by { |h| -h[:total] }
  end

  def dynamic_second_purchase_map
    rows = CustomerPurchaseSummary
      .where.not(first_series: nil, second_series: nil)
      .group(:first_series, :second_series)
      .count

    rows.group_by { |(first_series, _second_series), _count| first_series }.transform_values do |pairs|
      total = pairs.sum { |_k, count| count }.to_f

      pairs.map do |((_first_series, second_series), count)|
        pct = total.zero? ? 0 : ((count / total) * 100).round(1)
        [second_series, pct]
      end.sort_by { |(_series, pct)| -pct }.first(5)
    end
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
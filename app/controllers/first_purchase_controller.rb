# frozen_string_literal: true

class FirstPurchaseController < ApplicationController
  PER_PAGE = 20

  def index
    @series_options = CrmProduct.series_labels_for_filter
    @selected_series = params[:series].to_s.strip
    @silent_only = params[:silent_only] == "1"
    @growing_only = params[:growing_only] == "1"
    @sort = params[:sort].to_s.presence || "amount_desc"
    @page = [params[:page].to_i, 1].max

    scope = filtered_scope

    @total = Rails.cache.fetch(total_cache_key, expires_in: 10.minutes) do
      scope.distinct.count(:id)
    end

    @total_pages = [(@total.to_f / PER_PAGE).ceil, 1].max
    @customers = scope
      .select(customer_select_sql)
      .reorder(Arel.sql(sort_sql(@sort)))
      .offset((@page - 1) * PER_PAGE)
      .limit(PER_PAGE)

    @series_stats = Rails.cache.fetch("first_purchase:series_stats:v3", expires_in: 30.minutes) do
      series_stats_summary
    end

    @second_purchase_map = Rails.cache.fetch("first_purchase:second_purchase_map:v3", expires_in: 30.minutes) do
      dynamic_second_purchase_map
    end
  end

  # 匯出目前篩選條件下的「所有」符合客人（不分頁），供潛力客/沉默客名單大量匯出使用
  def export
    @selected_series = params[:series].to_s.strip
    @silent_only = params[:silent_only] == "1"
    @growing_only = params[:growing_only] == "1"
    @sort = params[:sort].to_s.presence || "amount_desc"

    customers = filtered_scope
      .select(customer_select_sql)
      .reorder(Arel.sql(sort_sql(@sort)))

    label = @growing_only ? "潛力客" : (@silent_only ? "沉默客" : "首購名單")
    label = "#{@selected_series}_#{label}" if @selected_series.present?

    send_data "\xEF\xBB\xBF" + export_csv(customers),
              filename: "#{label}_#{Date.today}.csv",
              type: "text/csv; charset=utf-8"
  end

  private

  def filtered_scope
    scope = ShoplineCustomer
      .joins("INNER JOIN customer_purchase_summaries cps ON cps.email = shopline_customers.email")
      .joins("LEFT JOIN customer_series_loyalties csl ON csl.email = shopline_customers.email AND csl.series = cps.first_series")

    scope = scope.where("cps.first_series = ?", @selected_series) if @selected_series.present?
    scope = scope.where("cps.silent_only = TRUE") if @silent_only
    scope = scope.where("csl.is_growing = TRUE") if @growing_only
    scope
  end

  def customer_select_sql
    <<~SQL.squish
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
      cps.silent_days_threshold,
      csl.is_growing AS growing,
      csl.growth_rate_pct AS growth_rate_pct,
      CASE
        WHEN cps.silent_only = TRUE
        THEN EXTRACT(DAY FROM NOW() - cps.first_date)::int
        ELSE NULL
      END AS silent_days
    SQL
  end

  def export_csv(customers)
    require "csv"

    CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["姓名", "Email", "會員等級", "首購系列", "首購日期", "首購金額", "累積消費", "訂單數", "成長幅度", "IG"]
      customers.each do |c|
        is_growing = ActiveModel::Type::Boolean.new.cast(c.try(:growing))
        csv << [
          c.full_name,
          c.email,
          c.membership_level,
          c.first_series.presence || c.first_product,
          c.first_date&.strftime("%Y/%m/%d"),
          c.first_amount.to_f.round(0).to_i,
          c.total_amount.to_f.round(0).to_i,
          c.purchase_count,
          is_growing ? "+#{c.growth_rate_pct}%" : "",
          c.instagram_account
        ]
      end
    end
  end

  def total_cache_key
    [
      "first_purchase:total:v3",
      @selected_series.presence || "all",
      @silent_only ? "silent" : "all_status",
      @growing_only ? "growing" : "all_growth"
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
        Arel.sql("SUM(CASE WHEN silent_only = TRUE THEN 1 ELSE 0 END)"),
        Arel.sql("SUM(CASE WHEN silent_only = TRUE OR purchase_count > 1 THEN 1 ELSE 0 END)")
      )

    rows.map do |series, total, returned, silent, eligible|
      total    = total.to_i
      returned = returned.to_i
      silent   = silent.to_i
      eligible = eligible.to_i

      {
        series:      series,
        total:       total,
        silent:      silent,
        returned:    returned,
        return_rate: eligible.zero? ? 0 : ((returned.to_f / eligible) * 100).round(1)
      }
    end.sort_by { |h| -h[:total] }
  end

  def dynamic_second_purchase_map
    rows = CustomerPurchaseSummary
      .where.not(first_series: nil, second_series: nil)
      .where("second_series <> ''")
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
    when "growth_desc"
      "csl.growth_rate_pct DESC NULLS LAST"
    else
      "shopline_customers.total_amount DESC NULLS LAST"
    end
  end
end
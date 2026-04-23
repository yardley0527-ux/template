# frozen_string_literal: true

class HighSpenderFirstPurchaseAnalytics
  def initialize(threshold:, year: nil, series: nil, repurchase_only: false)
    @threshold = threshold
    @year = year
    @series = series
    @repurchase_only = repurchase_only
  end

  def summary_cards
    total = filtered_base_scope.count
    repurchased = filtered_base_scope.where("purchase_count > 1").count
    silent = total - repurchased
    avg_first_amount = filtered_base_scope.average(:first_amount).to_f.round
    avg_purchase_count = filtered_base_scope.average(:purchase_count).to_f.round(2)

    [
      {
        label: "破萬新客總數",
        value: total,
        note: "首筆消費 >= #{@threshold}"
      },
      {
        label: "有回購人數",
        value: repurchased,
        note: total.zero? ? "0%" : "#{((repurchased.to_f / total) * 100).round(1)}%"
      },
      {
        label: "未回購人數",
        value: silent,
        note: total.zero? ? "0%" : "#{((silent.to_f / total) * 100).round(1)}%"
      },
      {
        label: "平均首筆金額",
        value: avg_first_amount,
        note: "平均購買次數 #{avg_purchase_count}"
      }
    ]
  end

  def year_stats
    rows = filtered_base_scope
      .where.not(first_date: nil)
      .group("EXTRACT(YEAR FROM first_date)")
      .pluck(
        Arel.sql("EXTRACT(YEAR FROM first_date)::int"),
        Arel.sql("COUNT(*)"),
        Arel.sql("SUM(CASE WHEN purchase_count > 1 THEN 1 ELSE 0 END)")
      )

    rows.map do |year, total, repurchased|
      total      = total.to_i
      repurchased = repurchased.to_i
      {
        year:            year,
        total:           total,
        repurchased:     repurchased,
        repurchase_rate: total.zero? ? 0 : ((repurchased.to_f / total) * 100).round(1)
      }
    end.sort_by { |h| h[:year] }
  end

  def monthly_stats
    rows = filtered_base_scope
      .where.not(first_date: nil)
      .group("DATE_TRUNC('month', first_date)")
      .pluck(
        Arel.sql("DATE_TRUNC('month', first_date)"),
        Arel.sql("COUNT(*)"),
        Arel.sql("AVG(first_amount)"),
        Arel.sql("SUM(CASE WHEN purchase_count > 1 THEN 1 ELSE 0 END)")
      )

    rows.map do |month_date, total, avg_first_amount, repurchased|
      total      = total.to_i
      repurchased = repurchased.to_i
      {
        month:            month_date.strftime("%Y-%m"),
        total:            total,
        avg_first_amount: avg_first_amount.to_f.round,
        repurchase_rate:  total.zero? ? 0 : ((repurchased.to_f / total) * 100).round(1)
      }
    end.sort_by { |h| h[:month] }
  end

  def monthly_series_breakdown
    rows = filtered_base_scope
      .where.not(first_date: nil, first_series: [nil, ""])
      .group("DATE_TRUNC('month', first_date)", :first_series)
      .pluck(
        Arel.sql("DATE_TRUNC('month', first_date)"),
        :first_series,
        Arel.sql("COUNT(*)")
      )

    rows.each_with_object({}) do |(month_date, series, count), hash|
      key = month_date.strftime("%Y-%m")
      hash[key] ||= []
      hash[key] << { series: series, count: count }
    end.transform_values { |arr| arr.sort_by { |h| -h[:count] }.first(4) }
  end

  def series_stats
    rows = filtered_base_scope
      .where.not(first_series: [nil, ""])
      .group(:first_series)
      .pluck(
        :first_series,
        Arel.sql("COUNT(*)"),
        Arel.sql("SUM(CASE WHEN purchase_count > 1 THEN 1 ELSE 0 END)"),
        Arel.sql("AVG(first_amount)")
      )

    rows.map do |series, total, repurchased, avg_first_amount|
      total      = total.to_i
      repurchased = repurchased.to_i
      {
        series:           series,
        total:            total,
        repurchased:      repurchased,
        repurchase_rate:  total.zero? ? 0 : ((repurchased.to_f / total) * 100).round(1),
        avg_first_amount: avg_first_amount.to_f.round
      }
    end.sort_by { |h| -h[:total] }
  end

  def second_purchase_map
    base = filtered_base_scope
      .where("purchase_count > 1")
      .where.not(first_series: [nil, ""], second_series: [nil, ""])

    rows = base.group(:first_series, :second_series).count

    rows.group_by { |(first_series, _), _| first_series }.transform_values do |pairs|
      total = pairs.sum { |_k, count| count }.to_f
      pairs.map do |((_, second_series), count)|
        {
          second_series: second_series,
          count:         count,
          rate:          total.zero? ? 0 : ((count / total) * 100).round(1)
        }
      end.sort_by { |h| -h[:count] }.first(5)
    end
  end

  def series_options
    CustomerPurchaseSummary
      .where("first_amount >= ?", @threshold)
      .where.not(first_series: [nil, ""])
      .distinct
      .order(:first_series)
      .pluck(:first_series)
  end

  private

  def filtered_base_scope
    scope = CustomerPurchaseSummary
      .where("first_amount >= ?", @threshold)

    scope = scope.where("EXTRACT(YEAR FROM first_date) = ?", @year.to_i) if @year.present?
    scope = scope.where(first_series: @series) if @series.present?
    scope = scope.where("purchase_count > 1") if @repurchase_only

    scope
  end
end

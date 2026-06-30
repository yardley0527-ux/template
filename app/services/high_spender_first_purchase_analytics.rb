# frozen_string_literal: true

class HighSpenderFirstPurchaseAnalytics
  # True repurchase: second order exists and is on a different calendar day
  REPURCHASED_SQL = "purchase_count > 1 AND second_date IS NOT NULL AND DATE_TRUNC('day', second_date) != DATE_TRUNC('day', first_date)"
  def initialize(threshold:, year: nil, series: nil, repurchase_only: false)
    @threshold = threshold
    @year = year
    @series = series
    @repurchase_only = repurchase_only
  end

  def summary_cards
    total              = filtered_base_scope.count
    repurchased        = filtered_base_scope.where(REPURCHASED_SQL).count
    silent             = total - repurchased
    avg_first_amount   = filtered_base_scope.average(:first_amount).to_f.round
    avg_purchase_count = filtered_base_scope.average(:purchase_count).to_f.round(2)

    [
      {
        label: "破萬新客總數",
        value: total,
        note: "首筆消費 >= #{@threshold}"
      },
      {
        label: "曾回購人數",
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
        Arel.sql("SUM(CASE WHEN #{REPURCHASED_SQL} THEN 1 ELSE 0 END)")
      )

    rows.map do |year, total, repurchased|
      total       = total.to_i
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
        Arel.sql("SUM(CASE WHEN #{REPURCHASED_SQL} AND DATE_TRUNC('month', second_date) = DATE_TRUNC('month', first_date) THEN 1 ELSE 0 END)")
      )

    rows.map do |month_date, total, avg_first_amount, repurchased_same_month|
      total                  = total.to_i
      repurchased_same_month = repurchased_same_month.to_i
      {
        month:                      month_date.strftime("%Y-%m"),
        total:                      total,
        avg_first_amount:           avg_first_amount.to_f.round,
        repurchase_rate_same_month: total.zero? ? 0 : ((repurchased_same_month.to_f / total) * 100).round(1)
      }
    end.sort_by { |h| h[:month] }.reverse
  end

  def monthly_series_breakdown
    @monthly_series_breakdown_cache ||= begin
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
  end

  def series_stats
    @series_stats_cache ||= begin
      rows = filtered_base_scope
        .where.not(first_series: [nil, ""])
        .group(:first_series)
        .pluck(
          :first_series,
          Arel.sql("COUNT(*)"),
          Arel.sql("SUM(CASE WHEN #{REPURCHASED_SQL} THEN 1 ELSE 0 END)"),
          Arel.sql("AVG(first_amount)")
        )

      rows.map do |series, total, repurchased, avg_first_amount|
        total       = total.to_i
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
  end

  def second_purchase_map
    base = filtered_base_scope
      .where(REPURCHASED_SQL)
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

  def anomaly_alerts
    breakdown = monthly_series_breakdown
    return [] if breakdown.size < 2

    sorted_months = breakdown.keys.sort.reverse
    current_month = sorted_months.first
    historical_months = sorted_months[1..3]
    return [] if historical_months.empty?

    current_counts = (breakdown[current_month] || []).index_by { |s| s[:series] }

    series_history = Hash.new { |h, k| h[k] = [] }
    historical_months.each do |m|
      (breakdown[m] || []).each { |s| series_history[s[:series]] << s[:count] }
    end

    alerts = []
    series_history.each do |series, counts|
      next if counts.size < 2
      hist_avg = counts.sum.to_f / counts.size
      next if hist_avg < 3

      current_count = current_counts[series]&.dig(:count) || 0
      drop_pct = hist_avg > 0 ? ((hist_avg - current_count) / hist_avg * 100).round(1) : 0

      if drop_pct >= 50
        alerts << {
          series:        series,
          current_count: current_count,
          hist_avg:      hist_avg.round(1),
          drop_pct:      drop_pct,
          month:         current_month
        }
      end
    end

    alerts.sort_by { |a| -a[:drop_pct] }
  end

  # Derived from series_stats — no extra query
  def series_options
    series_stats.map { |row| row[:series] }.sort
  end

  private

  def filtered_base_scope
    scope = CustomerPurchaseSummary
      .where("first_amount >= ?", @threshold)

    if @year.present?
      year_start = Date.new(@year.to_i, 1, 1)
      scope = scope.where(first_date: year_start...year_start.next_year)
    end
    scope = scope.where(first_series: @series) if @series.present?
    scope = scope.where(REPURCHASED_SQL) if @repurchase_only

    scope
  end
end

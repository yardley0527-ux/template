# frozen_string_literal: true

class ProductStrategyController < ApplicationController
  SERIES_OPTIONS = %w[
    代謝錠 全能 薑黃 膠原蛋白 美白 蝦紅素 清纖粉 魚油 私密粉 益生菌 穀胱甘肽 維DK鈣
  ].freeze

  def index
    @report = Rails.cache.fetch("product_strategy:report:v2", expires_in: 1.hour) do
      build_report
    end

    @overview = {
      total_customers:  @report.sum { |r| r[:total] },
      avg_return_rate:  (@report.sum { |r| r[:return_rate] } / @report.size).round(1),
      total_silent:     @report.sum { |r| r[:silent].to_i + r[:watching].to_i },
      total_iron:       @report.sum { |r| r[:iron] },
      best_retention:   @report.max_by { |r| r[:return_rate] }
    }
  end

  private

  def build_report
    # 各系列基本統計
    series_stats = CustomerPurchaseSummary
      .where.not(first_series: nil)
      .group(:first_series)
      .pluck(
        :first_series,
        Arel.sql("COUNT(*)"),
        Arel.sql("SUM(CASE WHEN purchase_count > 1 THEN 1 ELSE 0 END)"),
        Arel.sql("SUM(CASE WHEN silent_only = TRUE THEN 1 ELSE 0 END)"),
        Arel.sql("SUM(CASE WHEN purchase_count = 1 AND silent_only = FALSE THEN 1 ELSE 0 END)"),
        Arel.sql("AVG(first_amount)::numeric(10,0)"),
        Arel.sql("MAX(silent_days_threshold)")
      ).map do |series, total, returned, silent, watching, avg_first, threshold|
        return_rate = total.to_i.zero? ? 0.0 : (returned.to_f / total * 100).round(1)
        {
          series:      series,
          total:       total.to_i,
          returned:    returned.to_i,
          silent:      silent.to_i,
          watching:    watching.to_i,
          return_rate: return_rate,
          avg_first:   avg_first.to_i,
          threshold:   threshold.to_i
        }
      end.index_by { |r| r[:series] }

    # 忠實客 / 鐵粉數
    loyalty_stats = CustomerSeriesLoyalty
      .group(:series)
      .pluck(
        :series,
        Arel.sql("SUM(CASE WHEN tier = '忠實客' THEN 1 ELSE 0 END)"),
        Arel.sql("SUM(CASE WHEN tier = '鐵粉'  THEN 1 ELSE 0 END)"),
        Arel.sql("AVG(order_count)::numeric(10,1)")
      ).map do |series, loyal, iron, avg_count|
        [series, { loyal: loyal.to_i, iron: iron.to_i, avg_count: avg_count.to_f.round(1) }]
      end.to_h

    # 第二購方向（排除同系列回購，只看跨系列導流）
    second_purchase = CustomerPurchaseSummary
      .where.not(first_series: nil, second_series: nil)
      .where("second_series <> '' AND second_series <> first_series")
      .group(:first_series, :second_series)
      .count
      .group_by { |(first, _second), _count| first }
      .transform_values do |pairs|
        total = pairs.sum { |_k, count| count }.to_f
        pairs.map { |((_first, second), count)| [second, (count / total * 100).round(1)] }
             .sort_by { |(_s, pct)| -pct }
             .first(3)
      end

    SERIES_OPTIONS.map do |series|
      stat    = series_stats[series] || {}
      loyalty = loyalty_stats[series] || { loyal: 0, iron: 0, avg_count: 0 }
      second  = second_purchase[series] || []

      stat.merge(
        series:           series,
        loyal:            loyalty[:loyal],
        iron:             loyalty[:iron],
        avg_count:        loyalty[:avg_count],
        second_purchases: second,
        watching:         stat[:watching].to_i
      )
    end
  end
end
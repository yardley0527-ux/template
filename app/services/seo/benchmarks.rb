# frozen_string_literal: true

module Seo
  # 報告頁上的「浮動目標」與「比較基準」，直接從 seo_daily_metrics 算（不存進報告，
  # 回補資料後舊報告也會跟著更新）。全部以 GSC 最新資料日（end_date）往回算，
  # 並換算成「每 7 天」，才能跟卡片上的最近 7 天直接比。
  class Benchmarks
    def initialize(site, end_date)
      @site = site
      @end_date = end_date
    end

    # 本週目標：前 4 週（不含本週）的週平均 × (1 + 成長率)
    def weekly_target
      current = window(@end_date - 6..@end_date)
      base_range = (@end_date - 6 - Sites::TARGET_BASE_DAYS)..(@end_date - 7)
      base = weekly_average(base_range)
      return nil if base.nil? || base[:clicks].zero?

      target_clicks = (base[:clicks] * (1 + Sites::TARGET_GROWTH)).round
      {
        base_label: "#{base_range.first.strftime('%-m/%-d')}–#{base_range.last.strftime('%-m/%-d')}",
        clicks: current[:clicks], target_clicks: target_clicks, base_clicks: base[:clicks],
        progress_pct: [(current[:clicks] * 100.0 / target_clicks).round, 100].min,
        clicks_ok: current[:clicks] >= target_clicks,
        ctr: current[:ctr], ctr_target: base[:ctr], ctr_ok: current[:ctr].to_f >= base[:ctr].to_f,
        position: current[:position], position_target: base[:position],
        position_ok: current[:position].present? && base[:position].present? && current[:position] <= base[:position]
      }
    end

    def baselines
      current = window(@end_date - 6..@end_date)
      [
        ["近 90 天平均", weekly_average(@end_date - 89..@end_date)],
        ["SEO 合作期間平均", weekly_average(Sites::CONTRACT_PERIOD)],
        ["去年同期", window(@end_date - 6 - 365..@end_date - 365)]
      ].filter_map do |label, base|
        next if base.nil? || base[:clicks].zero? || base[:days] < 7

        base.merge(label: label, diff_pct: ((current[:clicks] - base[:clicks]) * 100.0 / base[:clicks]).round(1))
      end
    end

    # 趨勢圖的每日目標線：每一天都用它前 4 週的日平均 × (1 + 成長率)
    def self.daily_targets(clicks_by_date, dates)
      days = Sites::TARGET_BASE_DAYS
      dates.map do |date|
        prior = (1..days).filter_map { |i| clicks_by_date[date - i] }
        next nil if prior.size < days / 2

        (prior.sum.to_f / prior.size * (1 + Sites::TARGET_GROWTH)).round
      end
    end

    private

    def window(range)
      rows = SeoDailyMetric.for_site(@site).where(date: range)
      clicks = rows.sum(:clicks)
      impressions = rows.sum(:impressions)
      { clicks: clicks, impressions: impressions,
        ctr: impressions.positive? ? (clicks.to_f / impressions).round(4) : nil,
        position: impressions.positive? ? (rows.sum("position * impressions").to_f / impressions).round(1) : nil,
        days: rows.count }
    end

    def weekly_average(range)
      stats = window(range)
      return nil if stats[:days].zero?

      stats.merge(clicks: (stats[:clicks] * 7.0 / stats[:days]).round)
    end
  end
end

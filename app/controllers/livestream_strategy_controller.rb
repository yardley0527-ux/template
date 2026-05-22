# frozen_string_literal: true

class LivestreamStrategyController < ApplicationController
  LEVELS = %w[黑卡 金卡 銀卡 白卡].freeze

  def index
    all    = LivestreamAnalysisController::ALL_EVENTS
    e2024  = LivestreamAnalysisController::EVENTS_2024
    e2025  = LivestreamAnalysisController::EVENTS_2025
    e2026  = LivestreamAnalysisController::EVENTS_2026.select { |e| e[:date] <= Date.today }

    @years = [
      year_summary(2024, e2024),
      year_summary(2025, e2025),
      year_summary(2026, e2026)
    ]

    # 卡別年度平均出席人數
    @level_by_year = LEVELS.map do |level|
      {
        level: level,
        avg_2024: avg_attendance(e2024, level),
        avg_2025: avg_attendance(e2025, level),
        avg_2026: avg_attendance(e2026, level),
        trend_25: trend(avg_attendance(e2024, level), avg_attendance(e2025, level)),
        trend_26: trend(avg_attendance(e2025, level), avg_attendance(e2026, level))
      }
    end

    # 場次排行：業績前 10（有資料才算）
    @top_revenue = all.select { |e| e[:revenue] > 0 }
                      .sort_by { |e| -e[:revenue] }
                      .first(10)

    # 場次排行：出席人數前 10
    @top_attendance = all.sort_by { |e| -e[:levels].values.sum { |d| d[:n] } }.first(10)

    # 結論摘要
    @summaries = build_summaries(@years, @level_by_year)
  end

  private

  def year_summary(year, events)
    rev_events = events.select { |e| e[:revenue] > 0 }
    total_rev  = rev_events.sum { |e| e[:revenue] }
    total_ord  = events.sum { |e| e[:orders] }
    avg_rev    = rev_events.any? ? (total_rev.to_f / rev_events.size).round(0) : 0
    avg_ord    = events.any?     ? (total_ord.to_f / events.size).round(1)     : 0
    {
      year:         year,
      event_count:  events.size,
      rev_count:    rev_events.size,
      total_rev:    total_rev,
      total_orders: total_ord,
      avg_rev:      avg_rev,
      avg_orders:   avg_ord,
      best_event:   rev_events.max_by { |e| e[:revenue] }
    }
  end

  def avg_attendance(events, level)
    return 0 if events.empty?
    (events.sum { |e| e[:levels][level][:n] }.to_f / events.size).round(1)
  end

  def trend(prev, curr)
    return nil if prev.nil? || curr.nil? || prev.zero?
    pct = ((curr.to_f / prev - 1) * 100).round(0)
    { pct: pct, up: pct >= 0 }
  end

  def build_summaries(years, levels)
    items = []

    # 年度業績趨勢
    y25 = years.find { |y| y[:year] == 2025 }
    y26 = years.find { |y| y[:year] == 2026 }
    if y25 && y26 && y25[:avg_rev] > 0 && y26[:avg_rev] > 0
      pct = ((y26[:avg_rev].to_f / y25[:avg_rev] - 1) * 100).round(0)
      if pct >= 0
        items << { type: :success, text: "2026 場均業績 NT$#{fmt(y26[:avg_rev])}，較 2025 場均成長 #{pct}%。" }
      else
        items << { type: :warning, text: "2026 場均業績 NT$#{fmt(y26[:avg_rev])}，較 2025 場均下滑 #{pct.abs}%，建議檢視產品組合。" }
      end
    end

    # 成長最快的卡別
    best_grow = levels.select { |l| l[:trend_26] }.max_by { |l| l[:trend_26][:pct] }
    if best_grow && best_grow[:trend_26][:up]
      items << { type: :success, text: "#{best_grow[:level]} 2026 場均出席人數成長最快（↑#{best_grow[:trend_26][:pct]}%），是目前最活躍的客群。" }
    end

    # 流失最多的卡別
    worst = levels.select { |l| l[:trend_26] && !l[:trend_26][:up] }.min_by { |l| l[:trend_26][:pct] }
    if worst
      items << { type: :warning, text: "#{worst[:level]} 2026 場均出席下滑 #{worst[:trend_26][:pct].abs}%，需要特別關注。" }
    end

    # 最高業績場次
    top = @top_revenue.first
    if top
      items << { type: :info, text: "歷史最高業績場次為 #{top[:year]}/#{top[:label]}（#{top[:note]}），NT$#{fmt(top[:revenue])}，可參考此次產品組合。" }
    end

    items
  end

  def fmt(n)
    ActiveSupport::NumberHelper.number_to_delimited(n.to_i)
  end
end

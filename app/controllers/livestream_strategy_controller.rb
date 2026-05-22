# frozen_string_literal: true

class LivestreamStrategyController < ApplicationController
  LEVELS = %w[黑卡 金卡 銀卡 白卡].freeze

  SERIES_KEYWORDS = %w[薑黃 代謝錠 膠原 蝦紅素 NMN 魚油 穀胱甘肽 益生菌 清纖粉 美白 私密粉 維DK鈣 全能 B群].freeze

  def index
    all   = LivestreamAnalysisController::ALL_EVENTS
    e2024 = LivestreamAnalysisController::EVENTS_2024
    e2025 = LivestreamAnalysisController::EVENTS_2025
    e2026 = LivestreamAnalysisController::EVENTS_2026.select { |e| e[:date] <= Date.today }

    @years = [
      year_summary(2024, e2024),
      year_summary(2025, e2025),
      year_summary(2026, e2026)
    ]

    # 卡別年度平均出席
    @level_by_year = LEVELS.map do |level|
      {
        level:    level,
        avg_2024: avg_attendance(e2024, level),
        avg_2025: avg_attendance(e2025, level),
        avg_2026: avg_attendance(e2026, level),
        trend_25: trend(avg_attendance(e2024, level), avg_attendance(e2025, level)),
        trend_26: trend(avg_attendance(e2025, level), avg_attendance(e2026, level))
      }
    end

    # 場次排行
    @top_revenue    = all.select { |e| e[:revenue] > 0 }.sort_by { |e| -e[:revenue] }.first(10)
    @top_attendance = all.sort_by { |e| -e[:levels].values.sum { |d| d[:n] } }.first(10)

    # 1. 最佳直播月份
    monthly = Hash.new { |h, k| h[k] = { events: 0, rev: 0, rev_cnt: 0, att: 0 } }
    all.each do |e|
      m = e[:date].month
      monthly[m][:events] += 1
      monthly[m][:att]    += e[:levels].values.sum { |d| d[:n] }
      if e[:revenue] > 0
        monthly[m][:rev]     += e[:revenue]
        monthly[m][:rev_cnt] += 1
      end
    end
    @monthly_stats = (1..12).filter_map do |m|
      d = monthly[m]
      next if d[:events].zero?
      {
        month:   m,
        events:  d[:events],
        avg_rev: d[:rev_cnt] > 0 ? (d[:rev].to_f / d[:rev_cnt]).round(0) : nil,
        avg_att: (d[:att].to_f / d[:events]).round(1)
      }
    end

    # 2. 產品系列勝率
    series_data = Hash.new { |h, k| h[k] = { events: 0, rev: 0, rev_cnt: 0, att: 0 } }
    all.each do |e|
      matched = SERIES_KEYWORDS.select { |kw| e[:note].include?(kw) }
      matched = ["其他"] if matched.empty?
      matched.each do |kw|
        series_data[kw][:events] += 1
        series_data[kw][:att]    += e[:levels].values.sum { |d| d[:n] }
        if e[:revenue] > 0
          series_data[kw][:rev]     += e[:revenue]
          series_data[kw][:rev_cnt] += 1
        end
      end
    end
    @series_stats = series_data.filter_map do |name, d|
      {
        name:    name,
        events:  d[:events],
        avg_rev: d[:rev_cnt] > 0 ? (d[:rev].to_f / d[:rev_cnt]).round(0) : nil,
        avg_att: (d[:att].to_f / d[:events]).round(1)
      }
    end.sort_by { |s| -(s[:avg_rev] || 0) }

    # 3. 黑卡出席率趨勢
    @black_total = ShoplineCustomer.where(membership_level: "黑卡").count
    @black_by_year = [
      { year: 2024, events: e2024 },
      { year: 2025, events: e2025 },
      { year: 2026, events: e2026 }
    ].map do |row|
      evts   = row[:events]
      avg_n  = evts.empty? ? 0 : (evts.sum { |e| e[:levels]["黑卡"][:n] }.to_f / evts.size).round(1)
      rate   = @black_total > 0 ? (avg_n / @black_total * 100).round(1) : 0
      { year: row[:year], avg_n: avg_n, rate: rate, events: evts.size }
    end

    # 4. 場次間隔分析
    sorted = all.sort_by { |e| e[:date] }
    intervals = sorted.each_cons(2).map do |prev, curr|
      {
        gap:    (curr[:date] - prev[:date]).to_i,
        att:    curr[:levels].values.sum { |d| d[:n] },
        rev:    curr[:revenue],
        label:  "#{curr[:year]}/#{curr[:label]}"
      }
    end
    buckets = [
      { label: "7–14 天",  min: 7,  max: 14  },
      { label: "15–21 天", min: 15, max: 21  },
      { label: "22–30 天", min: 22, max: 30  },
      { label: "31–45 天", min: 31, max: 45  },
      { label: "46+ 天",   min: 46, max: 9999 }
    ]
    @gap_buckets = buckets.filter_map do |b|
      matching = intervals.select { |i| i[:gap] >= b[:min] && i[:gap] <= b[:max] }
      next if matching.empty?
      rev_events = matching.select { |i| i[:rev] > 0 }
      {
        label:   b[:label],
        count:   matching.size,
        avg_att: (matching.sum { |i| i[:att] }.to_f / matching.size).round(1),
        avg_rev: rev_events.any? ? (rev_events.sum { |i| i[:rev] }.to_f / rev_events.size).round(0) : nil
      }
    end
    best_gap = @gap_buckets.max_by { |b| b[:avg_att] }
    @best_gap_label = best_gap&.dig(:label)

    # 結論摘要
    @summaries = build_summaries
  end

  private

  def year_summary(year, events)
    rev_events = events.select { |e| e[:revenue] > 0 }
    total_rev  = rev_events.sum { |e| e[:revenue] }
    total_ord  = events.sum { |e| e[:orders] }
    {
      year:         year,
      event_count:  events.size,
      rev_count:    rev_events.size,
      total_rev:    total_rev,
      total_orders: total_ord,
      avg_rev:      rev_events.any? ? (total_rev.to_f / rev_events.size).round(0) : 0,
      avg_orders:   events.any?     ? (total_ord.to_f / events.size).round(1)     : 0,
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

  def build_summaries
    items = []

    y25 = @years.find { |y| y[:year] == 2025 }
    y26 = @years.find { |y| y[:year] == 2026 }
    if y25 && y26 && y25[:avg_rev] > 0 && y26[:avg_rev] > 0
      pct = ((y26[:avg_rev].to_f / y25[:avg_rev] - 1) * 100).round(0)
      if pct >= 0
        items << { type: :success, text: "2026 場均業績 NT$#{fmt(y26[:avg_rev])}，較 2025 場均成長 #{pct}%。" }
      else
        items << { type: :warning, text: "2026 場均業績 NT$#{fmt(y26[:avg_rev])}，較 2025 場均下滑 #{pct.abs}%，建議檢視產品組合。" }
      end
    end

    best_grow = @level_by_year.select { |l| l[:trend_26] }.max_by { |l| l[:trend_26][:pct] }
    if best_grow&.dig(:trend_26, :up)
      items << { type: :success, text: "#{best_grow[:level]} 2026 場均出席成長最快（↑#{best_grow[:trend_26][:pct]}%），是目前最活躍客群。" }
    end

    worst = @level_by_year.select { |l| l[:trend_26] && !l[:trend_26][:up] }.min_by { |l| l[:trend_26][:pct] }
    items << { type: :warning, text: "#{worst[:level]} 2026 場均出席下滑 #{worst[:trend_26][:pct].abs}%，需要特別關注。" } if worst

    top_series = @series_stats.find { |s| s[:avg_rev] }
    items << { type: :info, text: "產品系列中，「#{top_series[:name]}」場均業績最高（NT$#{fmt(top_series[:avg_rev])}），建議持續納入直播主打。" } if top_series

    best_month = @monthly_stats.select { |m| m[:avg_rev] }.max_by { |m| m[:avg_rev] }
    items << { type: :info, text: "#{best_month[:month]} 月是歷史場均業績最高的月份（NT$#{fmt(best_month[:avg_rev])}），建議每年安排重點場次。" } if best_month

    if @best_gap_label
      items << { type: :info, text: "場次間隔 #{@best_gap_label} 的直播，出席人數平均最高，建議作為排場頻率參考。" }
    end

    b26 = @black_by_year.find { |b| b[:year] == 2026 }
    b25 = @black_by_year.find { |b| b[:year] == 2025 }
    if b26 && b25 && b25[:avg_n] > 0
      pct = ((b26[:avg_n].to_f / b25[:avg_n] - 1) * 100).round(0)
      if pct >= 0
        items << { type: :success, text: "黑卡客戶 2026 場均出席 #{b26[:avg_n]} 人（↑#{pct}%），VIP 黏著度提升。" }
      else
        items << { type: :warning, text: "黑卡客戶 2026 場均出席 #{b26[:avg_n]} 人（↓#{pct.abs}%），建議加強 VIP 邀約。" }
      end
    end

    items
  end

  def fmt(n)
    ActiveSupport::NumberHelper.number_to_delimited(n.to_i)
  end
end

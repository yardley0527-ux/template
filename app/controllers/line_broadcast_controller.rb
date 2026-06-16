class LineBroadcastController < ApplicationController
  WEEKDAY_NAMES = %w[週一 週二 週三 週四 週五 週六 週日].freeze
  HOUR_SLOTS = [
    { label: "早上 10–12", range: (10..11) },
    { label: "中午 12–14", range: (12..13) },
    { label: "下午 14–18", range: (14..17) },
    { label: "晚上 20–22", range: (20..21) },
    { label: "深夜 22+",   range: (22..23) },
  ].freeze

  def index
    json_path = Rails.root.join("data", "line_broadcast_data.json")
    @data = File.exist?(json_path) ? JSON.parse(File.read(json_path)) : default_data

    # 直播日期（用來判斷「直播附近」）
    livestream_dates = Livestream.pluck(:date).map(&:to_date)

    # 所有推播加上衍生欄位
    all = (@data["broadcasts"] || []).map { |b| enrich(b, livestream_dates) }
                                     .sort_by { |b| b["push_time"] }

    @years        = all.map { |b| b["year"].to_i }.uniq.sort.reverse
    @selected_year = (params[:year]&.to_i || @years.first).to_i
    @broadcasts   = all.select { |b| b["year"].to_i == @selected_year }

    # ── 總覽數字 ──────────────────────────────────────────────────
    @total_broadcasts      = @broadcasts.size
    @total_revenue         = @broadcasts.sum { |b| b["revenue"].to_f }
    @total_orders          = @broadcasts.sum { |b| b["orders"].to_i }
    @avg_ctr               = avg(@broadcasts.map { |b| b["ctr"].to_f })
    @avg_read_rate         = avg(@broadcasts.map { |b| b["read_rate"].to_f })
    @near_livestream_count = @broadcasts.count { |b| b["near_days"] }
    @avg_revenue_per_push  = @total_broadcasts > 0 ? (@total_revenue / @total_broadcasts) : 0

    # ── 亮點推播 ──────────────────────────────────────────────────
    @best_revenue_broadcast = @broadcasts.max_by { |b| b["revenue"].to_f }
    @best_ctr_broadcast     = @broadcasts.max_by { |b| b["ctr"].to_f }
    @worst_unsub_broadcast  = @broadcasts.select { |b| b["unsubscribe_rate"].to_f > 0 }
                                         .max_by { |b| b["unsubscribe_rate"].to_f }

    # ── 月份成效表 ────────────────────────────────────────────────
    @monthly = @broadcasts.group_by { |b| b["push_time"].to_s[0..6] }.sort.reverse.map do |ym, rows|
      near_rows = rows.select { |b| b["near_days"] }
      {
        month:              ym[5..],
        count:              rows.size,
        revenue:            rows.sum { |b| b["revenue"].to_f }.round(0).to_i,
        orders:             rows.sum { |b| b["orders"].to_i },
        avg_read_rate:      avg(rows.map { |b| b["read_rate"].to_f })&.round(1),
        avg_ctr:            avg(rows.map { |b| b["ctr"].to_f })&.round(2),
        near_count:         near_rows.size,
        best:               rows.max_by { |b| b["revenue"].to_f }
      }
    end

    # ── 星期幾分析 ────────────────────────────────────────────────
    @weekday_stats = (0..6).map do |wday|
      rows = @broadcasts.select { |b| b["wday"] == wday }
      next if rows.empty?
      {
        label:         WEEKDAY_NAMES[wday],
        count:         rows.size,
        avg_revenue:   (rows.sum { |b| b["revenue"].to_f } / rows.size).round(0).to_i,
        avg_read_rate: avg(rows.map { |b| b["read_rate"].to_f })&.round(1),
        avg_ctr:       avg(rows.map { |b| b["ctr"].to_f })&.round(2)
      }
    end.compact

    # ── 時段分析 ─────────────────────────────────────────────────
    @hour_stats = HOUR_SLOTS.map do |slot|
      rows = @broadcasts.select { |b| slot[:range].include?(b["hour"]) }
      next if rows.empty?
      {
        label:         slot[:label],
        count:         rows.size,
        avg_revenue:   (rows.sum { |b| b["revenue"].to_f } / rows.size).round(0).to_i,
        avg_read_rate: avg(rows.map { |b| b["read_rate"].to_f })&.round(1),
        avg_ctr:       avg(rows.map { |b| b["ctr"].to_f })&.round(2)
      }
    end.compact

    # ── 直播附近的推播 ────────────────────────────────────────────
    @near_broadcasts = @broadcasts
      .select { |b| b["near_days"] }
      .sort_by { |b| b["near_days"].abs }

    # ── 亮點推播（有 image_url 的）────────────────────────────────
    @highlights = (@data["highlights"] || [])

    # ── 年份切換用摘要 ────────────────────────────────────────────
    @year_summary = @years.map do |y|
      rows = all.select { |b| b["year"].to_i == y }
      {
        year:    y,
        count:   rows.size,
        revenue: rows.sum { |b| b["revenue"].to_f }.round(0).to_i,
        orders:  rows.sum { |b| b["orders"].to_i }
      }
    end
  end

  private

  # 加上 wday / hour / near_days 欄位
  def enrich(b, livestream_dates)
    dt = DateTime.parse(b["push_time"]) rescue nil
    return b unless dt

    date   = dt.to_date
    wday   = (dt.wday + 6) % 7   # 0=週一 … 6=週日
    hour   = dt.hour

    # 距最近一場直播的天數（正數=直播後，負數=直播前）
    nearest = livestream_dates
      .min_by { |ld| (ld - date).abs }
    near_days = nearest ? (date - nearest).to_i : nil
    near_days = nil if near_days && near_days.abs > 3

    b.merge("wday" => wday, "hour" => hour, "near_days" => near_days, "dt" => dt)
  end

  def avg(arr)
    arr = arr.select { |v| v && v > 0 }
    arr.empty? ? nil : arr.sum / arr.size.to_f
  end

  def default_data
    { "broadcasts" => [], "highlights" => [], "last_updated" => nil,
      "product" => "", "channel" => "LINE 官方帳號" }
  end
end

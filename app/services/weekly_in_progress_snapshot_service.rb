# frozen_string_literal: true

# 「本週即時進度」——本週還沒結束時，不產生正式AI決策報告（那個假設一定拿
# 到完整7天資料，比較基準會失真），只給有時區/天數意識的部分期間數字：
# 本週截至目前 vs 上週同樣天數、日均營收、依目前日均推估的整週結果（明確
# 標示為推估）。純數字，不呼叫Claude、沒有決策/風險/機會判斷——這些判斷
# 留給週期結束後的正式週報。
class WeeklyInProgressSnapshotService
  def self.call(reference_date: Date.current)
    new(reference_date).call
  end

  def initialize(reference_date)
    @today = reference_date.to_date
    @period = WeeklyPeriod.new(@today)
    @prev_period = WeeklyPeriod.for_week_start(@period.prev_week_start)
    @days_elapsed = [(@today - @period.week_start).to_i + 1, 7].min
  end

  def call
    base = ShoplineOrder.valid_paid
    this_partial_range = @period.week_start.beginning_of_day..@today.end_of_day
    prev_same_elapsed_end = @prev_period.week_start + (@days_elapsed - 1)
    prev_same_elapsed_range = @prev_period.week_start.beginning_of_day..prev_same_elapsed_end.end_of_day

    this_stats = order_stats(base, this_partial_range)
    prev_same_elapsed_stats = order_stats(base, prev_same_elapsed_range)
    prev_full_week_stats = order_stats(base, @prev_period.time_range)

    daily_avg_this = safe_div(this_stats["revenue"], @days_elapsed)
    daily_avg_prev_same = safe_div(prev_same_elapsed_stats["revenue"], @days_elapsed)
    daily_avg_prev_full = safe_div(prev_full_week_stats["revenue"], 7)

    {
      "week_start"       => @period.week_start,
      "week_end"         => @period.week_end,
      "today"            => @today,
      "days_elapsed"     => @days_elapsed,
      "days_remaining"   => 7 - @days_elapsed,
      "is_complete"      => @period.complete?(@today),
      "this_week_partial"        => this_stats,
      "prev_week_same_elapsed"   => prev_same_elapsed_stats.merge("range_end" => prev_same_elapsed_end),
      "prev_week_full"           => prev_full_week_stats,
      "daily_avg_this_week"              => round2(daily_avg_this),
      "daily_avg_prev_week_same_elapsed" => round2(daily_avg_prev_same),
      "daily_avg_prev_week_full"         => round2(daily_avg_prev_full),
      "revenue_growth_pct_same_elapsed"  => round2(growth_pct(this_stats["revenue"], prev_same_elapsed_stats["revenue"])),
      "projected_full_week_revenue"      => round2(daily_avg_this * 7),
      "projection_note" => "依目前#{@days_elapsed}天的日均營收線性推估整週結果，僅供參考，不是正式預測，實際會隨週間銷售節奏（例如週末通常較高）調整"
    }
  end

  private

  def order_stats(scope, time_range)
    rows = scope.where(order_date: time_range)
                .group(:order_number)
                .pluck(Arel.sql("MAX(shopline_orders.email)"), Arel.sql("(#{ShoplineOrder::TOTAL_SQL})"))
    {
      "revenue" => round2(rows.sum { |_, t| t.to_f }),
      "orders"  => rows.size,
      "buyers"  => rows.map(&:first).uniq.size
    }
  end

  def safe_div(num, den)
    return 0.0 if den.to_f.zero?

    num.to_f / den.to_f
  end

  def growth_pct(current, previous)
    return nil if previous.to_f.zero?

    ((current.to_f - previous.to_f) / previous.to_f) * 100
  end

  def round2(n)
    n.to_f.round(2)
  end
end

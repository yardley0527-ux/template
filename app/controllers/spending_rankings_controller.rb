# frozen_string_literal: true

# 消費排行榜：三個排行榜 tab + 摘要卡名單模式 + 搜尋/篩選/分頁。
# 資料計算全部在 SpendingRankingsReport；這裡只處理參數、過濾與切頁。
#
# 排名一律先在全量資料完成（SpendingRankingsReport#rankings 已標 :rank），
# 搜尋與篩選只是把列藏起來，不會重新編名次。摘要卡永遠全量，不受任何參數影響。
class SpendingRankingsController < ApplicationController
  TABS = SpendingRankingsReport::TABS

  FOCUS = {
    "cooling" => { title: "流失警訊名單", subtitle: "2025 前 100 名中，2026 至今消費不到 2025 同期一半", rank_label: "2025 榜排名", period: :y2025 },
    "rising"  => { title: "上升新星名單", subtitle: "2026 前 100 名中，超越 2025 全年、NEW 或回流的客人", rank_label: "2026 榜排名", period: :y2026 }
  }.freeze

  TAB_PERIODS = { "y2025" => :y2025, "y2026" => :y2026, "total" => :total }.freeze
  PERIOD_LABELS = { y2025: "2025 全年", y2026: "2026/01/01 至今", total: "2025/01/01 至今" }.freeze

  LEVEL_OPTIONS = %w[黑卡 金卡 銀卡 白卡].freeze
  TREND_OPTIONS = {
    "new"       => "NEW",
    "returning" => "回流",
    "surpassed" => "超越去年",
    "cooling"   => "流失警訊",
    "stable"    => "穩定"
  }.freeze

  SILENT_DAYS = 60    # 最近消費超過 60 天標紅
  PER_PAGE    = 50

  def index
    @tab = TABS.key?(params[:tab]) ? params[:tab] : "y2025"
    @tab_config = TABS[@tab]
    @focus = FOCUS.key?(params[:focus]) ? params[:focus] : nil
    @focus_config = FOCUS[@focus]

    @q      = params[:q].to_s.strip
    @levels = Array(params[:levels]).select { |l| LEVEL_OPTIONS.include?(l) }
    @trends = Array(params[:trends]).select { |t| TREND_OPTIONS.key?(t) }

    report = SpendingRankingsReport.new
    @summary = report.summary
    @same_period_end = report.same_period_end_date

    base = base_list(report)

    snapshots = report.customer_snapshots(base.map { |t| t[:email] })
    all_rows = base.map { |t| build_row(t, snapshots[t[:email]], report) }

    filtered = apply_search(apply_filters(all_rows))

    @total_count = filtered.size
    @total_pages = [(@total_count.to_f / PER_PAGE).ceil, 1].max
    @page = [params[:page].to_i, 1].max
    @page = @total_pages if @page > @total_pages
    @rows = filtered[(@page - 1) * PER_PAGE, PER_PAGE] || []

    period = @focus_config ? @focus_config[:period] : TAB_PERIODS[@tab]
    ids_by_email = @rows.to_h { |r| [r[:email], r[:shopline_customer_id]] }
    @details = report.management_details(@rows.map { |r| r[:email] }, period: period, customer_ids_by_email: ids_by_email)
  end

  private

  # 榜單本體（已含全量計得的 :rank；focus 名單沿用來源榜名次）
  def base_list(report)
    case @focus
    when "cooling"
      report.rankings["y2025"].select { |t| report.cooling?(t) }
    when "rising"
      report.rankings["y2026"].select { |t| SpendingRankingsReport::RISING_TRENDS.include?(report.trend_for(t)) }
    else
      report.rankings[@tab]
    end
  end

  def build_row(t, snapshot, report)
    c = snapshot || {}
    r25 = report.full_rank_2025[t[:email]]
    r26 = report.full_rank_2026[t[:email]]
    silent_days = t[:last_paid_order_at] ? (Date.current - t[:last_paid_order_at].to_date).to_i : nil
    trend = report.trend_for(t)
    {
      rank: t[:rank],
      email: t[:email],
      full_name: c["full_name"],
      instagram_account: c["instagram_account"],
      membership_level: c["membership_level"],
      shopline_customer_id: c["id"],
      amount_2025: t[:amount_2025],
      amount_2025_ytd: t[:amount_2025_ytd],
      amount_2026: t[:amount_2026],
      amount_total: t[:amount_total],
      yoy_change: t[:amount_2026] - t[:amount_2025_ytd],
      yoy_rate: t[:amount_2025_ytd].positive? ? ((t[:amount_2026] - t[:amount_2025_ytd]) * 100.0 / t[:amount_2025_ytd]).round(1) : nil,
      trend: trend,
      rank_2025: r25,
      rank_2026: r26,
      last_order_date: t[:last_paid_order_at],
      silent_days: silent_days
    }
  end

  def apply_filters(rows)
    rows = rows.select { |r| @levels.include?(r[:membership_level]) } if @levels.any?
    rows = rows.select { |r| @trends.include?(r[:trend].to_s) } if @trends.any?
    rows
  end

  # 搜尋姓名 / IG（有無 @ 皆可）/ Email，不分大小寫、忽略前後空白、支援部分比對
  def apply_search(rows)
    return rows if @q.blank?

    needle = @q.downcase.delete_prefix("@")
    rows.select do |r|
      r[:full_name].to_s.downcase.include?(needle) ||
        r[:instagram_account].to_s.downcase.delete_prefix("@").include?(needle) ||
        r[:email].to_s.include?(needle)
    end
  end
end

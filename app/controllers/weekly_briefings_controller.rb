# frozen_string_literal: true

# 每週經營決策報告頁面。報告本身一律由 WeeklyBriefingRunner 落地產生
# （排程或手動觸發），這裡只負責讀取已落地的資料＋提供管理員手動
# 重新產生的入口，跟 DailyBriefing／首頁的關係一致。
#
# 2026-09-15 修正：regenerate 改呼叫 WeeklyBriefingRunner（跟 rake task 共用
# 同一份「先確認上游快取夠不夠新鮮、需要才刷新」邏輯），不再只重算數據卻跳過
# crm_customer_product_cycles——那個跳過正是「商品回購全部為0」的根因。
#
# 2026-09-15 第五輪修正：/weekly_briefings/current 原本直接用 Date.current
# 所在的那一週，導致正式站在週二看到「只過了兩天的本週」被當成正式週報，
# 拿去跟上週完整七天比較，產生「營收暴跌89%」這種不可比較的假結論。改成
# current 一律解析成「最新一個已完整結束的週」；本週尚未結束時要看即時
# 進度，改走 #in_progress（不呼叫AI、不產生正式決策報告，只給有時區意識
# 的部分期間比較數字）。regenerate 也擋下對未結束週期的請求，從源頭避免
# 同類問題再發生一次。
class WeeklyBriefingsController < ApplicationController
  before_action :set_briefing, only: [:show, :regenerate]

  def index
    @briefings = WeeklyBriefing.history.limit(53)
  end

  def show
    @history = WeeklyBriefing.history.limit(53)
  end

  def in_progress
    @period = WeeklyPeriod.new(Date.current)
    @snapshot = WeeklyInProgressSnapshotService.call(reference_date: Date.current)
  end

  def regenerate
    unless current_user.admin?
      redirect_to weekly_briefing_path(week_start: @week_start.to_s), alert: "只有管理員可以重新產生報告"
      return
    end

    unless @period.complete?
      redirect_to weekly_briefing_path(week_start: @week_start.to_s),
                  alert: "#{@period.week_start}~#{@period.week_end} 這一週尚未結束，正式週報只在週期結束後產生；" \
                         "想看目前進度請到「查看本週即時進度」頁面。"
      return
    end

    _briefing, refresh_log = WeeklyBriefingRunner.call(week_start: @week_start)
    refreshed = refresh_log.select { |_, v| v == "refreshed" || v.to_s.start_with?("refreshed") }.keys
    notice = refreshed.any? ? "已重新產生最新完整週報（順便刷新了：#{refreshed.join('、')}）" : "已重新產生最新完整週報"
    redirect_to weekly_briefing_path(week_start: @week_start.to_s), notice: notice
  end

  private

  def set_briefing
    @week_start = parse_week_start(params[:week_start])
    @period = WeeklyPeriod.new(@week_start)
    @week_start = @period.week_start
    @briefing = WeeklyBriefing.find_by(week_start: @week_start)
  end

  def parse_week_start(value)
    return WeeklyPeriod.latest_complete_week_start if value.blank? || value == "current"

    Date.parse(value)
  rescue ArgumentError, TypeError
    WeeklyPeriod.latest_complete_week_start
  end
end

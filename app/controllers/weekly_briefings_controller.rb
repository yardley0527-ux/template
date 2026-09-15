# frozen_string_literal: true

# 每週經營決策報告頁面。報告本身一律由 WeeklyBriefingRunner 落地產生
# （排程或手動觸發），這裡只負責讀取已落地的資料＋提供管理員手動
# 重新產生的入口，跟 DailyBriefing／首頁的關係一致。
#
# 2026-09-15 修正：regenerate 改呼叫 WeeklyBriefingRunner（跟 rake task 共用
# 同一份「先確認上游快取夠不夠新鮮、需要才刷新」邏輯），不再只重算數據卻跳過
# crm_customer_product_cycles——那個跳過正是「商品回購全部為0」的根因。
class WeeklyBriefingsController < ApplicationController
  before_action :set_briefing, only: [:show, :regenerate]

  def index
    @briefings = WeeklyBriefing.history.limit(53)
  end

  def show
    @history = WeeklyBriefing.history.limit(53)
  end

  def regenerate
    unless current_user.admin?
      redirect_to weekly_briefing_path(week_start: @week_start.to_s), alert: "只有管理員可以重新產生報告"
      return
    end

    _briefing, refresh_log = WeeklyBriefingRunner.call(week_start: @week_start)
    refreshed = refresh_log.select { |_, v| v == "refreshed" || v.to_s.start_with?("refreshed") }.keys
    notice = refreshed.any? ? "已重新產生本週報告（順便刷新了：#{refreshed.join('、')}）" : "已重新產生本週報告"
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
    return Date.current if value.blank? || value == "current"

    Date.parse(value)
  rescue ArgumentError, TypeError
    Date.current
  end
end

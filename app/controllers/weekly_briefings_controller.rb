# frozen_string_literal: true

# 每週營運檢討報告頁面。報告本身一律由 WeeklyBriefingService 落地產生
# （排程或手動觸發），這裡只負責讀取已落地的資料＋提供管理員手動
# 重新產生的入口，跟 DailyBriefing／首頁的關係一致。
class WeeklyBriefingsController < ApplicationController
  before_action :set_briefing, only: [:show, :regenerate]

  def index
    @briefings = WeeklyBriefing.history.limit(53)
  end

  def show
    @history = WeeklyBriefing.history.limit(53)
  end

  # 手動重新產生：只重算數據＋重跑 AI 解讀，不重新整理直播／回購等上游快取
  # （那些由 ops:weekly_briefing rake task／排程負責，避免這個按鈕在網頁請求
  # 內做太重的整表刷新）。管理員限定——一般角色只能看,不能觸發重算。
  def regenerate
    unless current_user.admin?
      redirect_to weekly_briefing_path(week_start: @week_start.to_s), alert: "只有管理員可以重新產生報告"
      return
    end

    WeeklyBriefingService.call(week_start: @week_start)
    redirect_to weekly_briefing_path(week_start: @week_start.to_s), notice: "已重新產生本週報告"
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

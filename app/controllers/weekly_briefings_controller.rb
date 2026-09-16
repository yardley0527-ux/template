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
#
# 2026-09-16：regenerate 改成背景 job（WeeklyBriefingRegenerationJob）+
# 前端輪詢——上游13個商品回購週期重算＋最多3次Opus API往返實測要好幾分鐘，
# 原本同步執行會讓管理員的瀏覽器請求卡住直到超時。#status 給輪詢用。
class WeeklyBriefingsController < ApplicationController
  before_action :set_briefing, only: [:show]
  before_action :set_briefing_for_write, only: [:regenerate, :status]

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

    if @briefing.regenerating?
      redirect_to weekly_briefing_path(week_start: @week_start.to_s), alert: "上一次重新產生還在背景處理中，請稍候"
      return
    end

    @briefing.update!(regeneration_started_at: Time.current)
    WeeklyBriefingRegenerationJob.perform_later(@week_start.to_s)
    redirect_to weekly_briefing_path(week_start: @week_start.to_s),
                notice: "已加入背景處理，通常需要幾分鐘（要重算商品回購週期＋呼叫AI），這頁會自動偵測完成，離開也不影響"
  end

  # 前端輪詢用：跟 imports 頁的 #status 同一種模式。
  def status
    render json: {
      regenerating: @briefing.regenerating?,
      status: @briefing.status,
      generated_at: @briefing.generated_at,
      needs_review: @briefing.needs_review_banner?
    }
  end

  private

  def set_briefing
    @week_start = parse_week_start(params[:week_start])
    @period = WeeklyPeriod.new(@week_start)
    @week_start = @period.week_start
    @briefing = WeeklyBriefing.find_by(week_start: @week_start)
  end

  # regenerate／status 需要一筆可以讀寫 regeneration_started_at 的 row，
  # 跟 #show 故意保留「這週從沒產生過」時 @briefing 是 nil（畫面顯示空狀態）
  # 的行為不同，所以分開一個 before_action，不共用 set_briefing。
  def set_briefing_for_write
    @week_start = parse_week_start(params[:week_start])
    @period = WeeklyPeriod.new(@week_start)
    @week_start = @period.week_start
    @briefing = WeeklyBriefing.for_week(@week_start)
    @briefing.week_end ||= @period.week_end
  end

  def parse_week_start(value)
    return WeeklyPeriod.latest_complete_week_start if value.blank? || value == "current"

    Date.parse(value)
  rescue ArgumentError, TypeError
    WeeklyPeriod.latest_complete_week_start
  end
end

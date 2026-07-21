# 方案 B PR3：直播成效總覽。只讀 PR2 寫入的統計快取欄位＋calendar_events
# 未來排程，不觸發任何刷新、不寫入任何統計。
class LivestreamOverviewController < ApplicationController
  def index
    @next_event = CalendarEvent.where(event_type: "livestream")
                                .where("event_date >= ?", Date.current)
                                .order(:event_date)
                                .first

    @latest   = Livestream.where("date <= ?", Date.current).order(date: :desc).first
    @previous = @latest && Livestream.where("date < ?", @latest.date).order(date: :desc).first

    @sync_run = SyncRun.latest_for("livestream_stats")
    @product_labels = CrmProduct.pluck(:key, :label).to_h
  end
end

# 直播週期缺口規則（livestream_schedule_gap）需要「暫停週期期間不提醒」的例外機制
# （公司排定的長假、休播期）。重用既有 CalendarEvent 而不是新開一張表：加一個
# 可選的 end_date 讓事件可以表示一段區間（原本只有單日 event_date，既有事件
# end_date 一律為 nil，行為不變），並新增 event_type=livestream_pause。
class AddEndDateAndPauseTypeToCalendarEvents < ActiveRecord::Migration[7.1]
  def change
    add_column :calendar_events, :end_date, :date
  end
end

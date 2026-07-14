# frozen_string_literal: true

# 首頁（指揮中心）的資料組裝：下一場直播/到貨、部門今日回報狀態、同步健康。
# 只讀既有資料，不做任何寫入。
class CommandCenterSnapshot
  def self.call
    new.call
  end

  def call
    radar = CampaignReadinessScan.call
    {
      next_livestream:   upcoming_event("livestream"),
      next_arrival:      upcoming_event("arrival"),
      upcoming_events:   upcoming_all(limit: 5),
      department_lights: department_lights,
      radar:             radar,
      risks:             OpsRiskScan.call(radar: radar),
      briefing:          DailyBriefing.latest,
      bulletin_notes:    BulletinNote.board,
      sync_alerts:       SyncRun.current_alerts,
      sync_last_run:     DepartmentSheetSync.last_run_at
    }
  end

  private

  def upcoming_event(type)
    CalendarEvent.where(event_type: type)
                 .where(event_date: Date.current..)
                 .order(:event_date, :created_at)
                 .first
  end

  def upcoming_all(limit:)
    CalendarEvent.where(event_date: Date.current..)
                 .order(:event_date, :created_at)
                 .limit(limit)
  end

  # 部門日誌通常在當天陸續寫入；早上看到昨天已回報、今天還沒寫是正常狀態，
  # 所以燈號同時給「今日有無」與「最後回報日」兩個訊號。
  def department_lights
    reported_today = DepartmentUpdate.where(log_date: Date.current).pluck(:department).to_set
    last_dates     = DepartmentUpdate.group(:department).maximum(:log_date)
    note_counts    = BulletinNote.open_counts_by_department

    DepartmentUpdate::DEPARTMENTS.map do |dept|
      {
        department:     dept,
        reported_today: reported_today.include?(dept),
        last_date:      last_dates[dept],
        open_notes:     note_counts[dept].to_i
      }
    end
  end
end

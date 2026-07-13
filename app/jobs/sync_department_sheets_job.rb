class SyncDepartmentSheetsJob < ApplicationJob
  queue_as :default

  # 超過 1 小時沒同步就在背景重抓；先標記時間戳避免多個 request 重複觸發。
  # 行事曆頁與首頁共用這個入口；Render Cron 的 rake ops:sync 是主要排程，這裡是備援。
  def self.schedule_if_stale
    return unless DepartmentSheetSync.stale?

    DepartmentSheetSync.mark_run!
    perform_later
  end

  def perform
    DepartmentSheetSync.call
    AnnualCalendarSync.call
  end
end

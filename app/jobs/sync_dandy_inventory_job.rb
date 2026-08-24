class SyncDandyInventoryJob < ApplicationJob
  queue_as :default

  # 產品庫存頁造訪時的備援同步；主要排程在 Render Cron 的 rake ops:sync。
  def self.schedule_if_stale
    return unless DandyInventorySync.stale?

    DandyInventorySync.mark_run!
    perform_later
  end

  def perform
    result = DandyInventorySync.call
    CrmProductInventorySync.call if result[:error].nil?
  end
end

# path: app/jobs/refresh_livestream_stats_job.rb

# 方案 B PR2：觸發 LivestreamStatsRefreshService。呼叫端一律用 perform_now
# （不用 perform_later）——production queue adapter 是 :async（記憶體佇列），
# 而 import:paid_orders 是一次性 rake process，process 結束後記憶體佇列裡
# 尚未執行的 job 會直接遺失；perform_now 在呼叫端所在的 process 內同步執行，
# 不依賴任何佇列的存活保證。也可用 rails livestreams:stats:refresh 手動補跑。
class RefreshLivestreamStatsJob < ApplicationJob
  queue_as :default

  def perform(date: nil)
    run = LivestreamStatsRefreshService.call(date: date)
    Rails.logger.info "[RefreshLivestreamStatsJob] sync_run_id=#{run.id} status=#{run.status}"
    run
  end
end

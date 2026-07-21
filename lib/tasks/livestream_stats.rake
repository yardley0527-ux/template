# frozen_string_literal: true

# 方案 B PR2：手動刷新直播統計快取。
#
#   rails livestreams:stats:refresh                 # 全量刷新
#   DATE=2026-06-05 rails livestreams:stats:refresh  # 單場刷新
namespace :livestreams do
  namespace :stats do
    desc "刷新 livestreams 統計快取（全量，或 DATE=YYYY-MM-DD 單場）"
    task refresh: :environment do
      date = ENV["DATE"].presence && Date.parse(ENV["DATE"])
      puts "[livestreams:stats:refresh] 若另一個刷新正在執行中，本次會等待其完成後才開始（blocking lock）..."
      result = LivestreamStatsRefreshService.call(date: date)

      puts "[livestreams:stats:refresh] SyncRun id=#{result.id} status=#{result.status} " \
           "succeeded=#{result.meta['succeeded']} failed=#{result.meta['failed']}"
      if result.error_messages.present?
        puts "[livestreams:stats:refresh] errors:"
        result.error_messages.each { |m| puts "  #{m}" }
      end
    end
  end
end

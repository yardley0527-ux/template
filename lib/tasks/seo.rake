# frozen_string_literal: true
#
# SEO 每日監控（Search Console + 網站健康檢查）。需要 SEO_GOOGLE_SA_JSON。
#
#   bundle exec rake seo:daily                 # 產生今天的 SeoReport（Render Cron，排在 ops:notifications 之前）
#   DAYS=480 bundle exec rake seo:backfill     # 回補 Search Console 每日總數（GSC 最多保留 16 個月）

namespace :seo do
  desc "Generate today's SEO report (Search Console sync + health checks)"
  task daily: :environment do
    report = Seo::DailyReportService.call
    puts "[seo:daily] report_date=#{report.report_date} status=#{report.status} error=#{report.error_message || 'none'}"
    report.checks.reject { |c| c["level"] == "ok" }.each do |c|
      puts "  [#{c['level']}] #{c['site']} #{c['label']}: #{c['detail']}"
    end
  end

  desc "Backfill Search Console daily totals. DAYS=480 by default."
  task backfill: :environment do
    days = (ENV["DAYS"] || 480).to_i
    counts = Seo::SearchConsole.new.sync_daily!(start_date: Date.current - days, end_date: Date.current)
    puts "[seo:backfill] #{counts}"
  end
end

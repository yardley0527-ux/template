# frozen_string_literal: true
#
# SEO 每日監控（Search Console + 網站健康檢查）。需要 SEO_GOOGLE_SA_JSON。
#
#   bundle exec rake seo:daily                 # 產生今天的 SeoReport（Render Cron，排在 ops:notifications 之前）
#   DAYS=480 bundle exec rake seo:backfill     # 回補 Search Console 每日總數（GSC 最多保留 16 個月）
#   FORCE=1 bundle exec rake seo:line_digest   # 手動重發 LINE 摘要（seo:daily 平日會自動發）

namespace :seo do
  desc "Generate today's SEO report (Search Console sync + health checks)"
  task daily: :environment do
    report = Seo::DailyReportService.call
    puts "[seo:daily] report_date=#{report.report_date} status=#{report.status} error=#{report.error_message || 'none'}"
    report.checks.reject { |c| c["level"] == "ok" }.each do |c|
      puts "  [#{c['level']}] #{c['site']} #{c['label']}: #{c['detail']}"
    end

    # 平日才推 LINE 給部門主管（週末數據變化小）；推播失敗不影響報告本身
    if report.status != "failed" && Date.current.on_weekday?
      begin
        puts "[seo:daily] LINE 推播 #{Seo::LineDigest.call(report)} 個群組"
      rescue StandardError => e
        puts "[seo:daily] LINE 推播失敗：#{e.class}: #{e.message}"
      end
    end
  end

  desc "Push the latest SEO report to the LINE groups. FORCE=1 re-sends even if already sent."
  task line_digest: :environment do
    report = SeoReport.latest or abort("[seo:line_digest] 還沒有 SEO 報告")
    puts "[seo:line_digest] 推播 #{Seo::LineDigest.call(report, force: ENV['FORCE'].present?)} 個群組"
  end

  desc "Backfill Search Console daily totals. DAYS=480 by default."
  task backfill: :environment do
    days = (ENV["DAYS"] || 480).to_i
    counts = Seo::SearchConsole.new.sync_daily!(start_date: Date.current - days, end_date: Date.current)
    puts "[seo:backfill] #{counts}"
  end
end

# frozen_string_literal: true
#
# SEO 每日監控（Search Console + 網站健康檢查）。需要 SEO_GOOGLE_SA_JSON。
#
#   bundle exec rake seo:daily                 # 產生今天的 SeoReport（Render Cron，排在 ops:notifications 之前）
#   DAYS=480 bundle exec rake seo:backfill     # 回補 Search Console 每日總數（GSC 最多保留 16 個月）
#   FORCE=1 bundle exec rake seo:line_digest   # 手動重發 LINE 摘要（seo:daily 平日會自動發）
#   bundle exec rake seo:site_audit            # 官網全站健檢（約 30 分鐘）；seo:daily 週五會自動跑並推 LINE
#     MAX_PAGES=30 只檢查前 30 頁（測試用）、NO_LINE=1 不推 LINE、FORCE=1 已推過也重推

namespace :seo do
  desc "Generate today's SEO report (Search Console sync + health checks)"
  task daily: :environment do
    report = Seo::DailyReportService.call
    puts "[seo:daily] report_date=#{report.report_date} status=#{report.status} error=#{report.error_message || 'none'}"
    report.checks.reject { |c| c["level"] == "ok" }.each do |c|
      puts "  [#{c['level']}] #{c['site']} #{c['label']}: #{c['detail']}"
    end

    # 平日才推 LINE 給部門主管（週末數據變化小）；推播失敗不影響報告本身
    # LINE 摘要會打 Claude API 寫重點，AI 報告暫停期間不推（報告本身照常產生）
    if AiReports.paused?
      puts "[seo:daily] LINE 推播：#{AiReports::PAUSED_NOTE}，略過"
    elsif report.status != "failed" && Date.current.on_weekday?
      begin
        puts "[seo:daily] LINE 推播 #{Seo::LineDigest.call(report)} 個群組"
      rescue StandardError => e
        puts "[seo:daily] LINE 推播失敗：#{e.class}: #{e.message}"
      end
    end

    # 週五做官網全站健檢並推總編輯群組（不用 AI，AI 暫停期間照發）；約 30 分鐘，放在 SEO 日報之後
    if Date.current.friday?
      begin
        audit = Seo::SiteAudit.new.run!
        puts "[seo:daily] 全站健檢 #{audit.pages_checked} 頁、#{audit.issues.size} 項問題；推播 #{Seo::SiteAuditDigest.call(audit)} 個群組"
      rescue StandardError => e
        puts "[seo:daily] 全站健檢失敗：#{e.class}: #{e.message}"
      end
    end

    # 這支 Cron 剛好是台灣 10:00 跑，週一順便發 CRM 群組的生日名單（跟 SEO 報告無關，失敗互不影響）
    if Date.current.monday?
      begin
        puts "[seo:daily] 生日名單推播 #{CrmBirthdays::LineDigest.call} 個群組"
      rescue StandardError => e
        puts "[seo:daily] 生日名單推播失敗：#{e.class}: #{e.message}"
      end
    end
  end

  desc "Push the latest SEO report to the LINE groups. FORCE=1 re-sends even if already sent."
  task line_digest: :environment do
    abort("[seo:line_digest] #{AiReports::PAUSED_NOTE}") if AiReports.paused?
    report = SeoReport.latest or abort("[seo:line_digest] 還沒有 SEO 報告")
    puts "[seo:line_digest] 推播 #{Seo::LineDigest.call(report, force: ENV['FORCE'].present?)} 個群組"
  end

  desc "Weekly full-site audit of yardley.tw. MAX_PAGES= NO_LINE=1 FORCE=1"
  task site_audit: :environment do
    max = ENV["MAX_PAGES"].presence&.to_i
    audit = Seo::SiteAudit.new(max_pages: max).run!
    digest = Seo::SiteAuditDigest.new(audit)
    puts digest.message
    next if ENV["NO_LINE"].present?

    puts "[seo:site_audit] 推播 #{Seo::SiteAuditDigest.call(audit, force: ENV['FORCE'].present?)} 個群組"
  end

  # 加強版每週報告（AI 暫停中由 Claude 本機寫）：
  #   rake seo:weekly_facts                 # 印出每頁實際被搜的字＋目前標題／描述／H2
  #   rake seo:weekly_advice FILE=advice.txt # 寫好的「具體怎麼改」存進最新一份，報告中心顯示可複製
  desc "Print per-page search queries and current title/description/H2 of the latest weekly audit"
  task weekly_facts: :environment do
    audit = SeoSiteAudit.where(site: Seo::SiteAudit::SITE).order(:audited_on).last or abort("還沒有每週報告")
    ins = audit.insights
    puts "#{audit.audited_on}（搜尋數據 #{ins['data_range']&.join('–')}）"
    Seo::WeeklyInsights.referenced_pages(ins).each do |url|
      key = Seo::SiteAudit.page_key(url)
      meta = ins.dig("page_meta", key) || {}
      puts "\n== #{key}", "標題：#{meta['title'] || ins.dig('titles', key)}", "描述：#{meta['description']}"
      puts "H2：#{meta['h2'].to_a.join('／')}"
      ins.dig("page_queries", url).to_a.each { |q, imp, clk, pos| puts "  #{q}｜曝光 #{imp}・點擊 #{clk}・排名 #{pos}" }
    end
  end

  desc "Save hand-written weekly advice (FILE=) into the latest weekly audit"
  task weekly_advice: :environment do
    text = File.read(ENV.fetch("FILE")).strip
    audit = SeoSiteAudit.where(site: Seo::SiteAudit::SITE).order(:audited_on).last or abort("還沒有每週報告")
    audit.update!(insights: audit.insights.merge("manual_advice" => text))
    puts "[seo:weekly_advice] 已存進 #{audit.audited_on}（#{text.length} 字）"
  end

  desc "Backfill Search Console daily totals. DAYS=480 by default."
  task backfill: :environment do
    days = (ENV["DAYS"] || 480).to_i
    counts = Seo::SearchConsole.new.sync_daily!(start_date: Date.current - days, end_date: Date.current)
    puts "[seo:backfill] #{counts}"
  end
end

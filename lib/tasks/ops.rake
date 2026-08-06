# frozen_string_literal: true

# 營運資料同步（給 Render Cron Job 用；本機也可手動跑）。
# 排程：Render「Daily Brief」cron 每天 UTC 23:30 跑 ops:sync ops:briefing。
# 頁面上的背景備援同步已移除（曾在 512MB web instance 觸發 OOM）；
# 臨時要更新用首頁的手動同步按鈕。
namespace :ops do
  desc "同步部門日誌 Google Sheets 與年度行事曆 Excel"
  task sync: :environment do
    dept = DepartmentSheetSync.call
    dept.each do |department, result|
      status = result[:error] ? "FAILED: #{result[:error]}" : "#{result[:dates]} days"
      puts "[ops:sync] #{department}: #{status}"
    end

    annual = AnnualCalendarSync.call
    puts "[ops:sync] 年度行事曆: #{annual[:error] || "#{annual[:events]} events"}"

    inventory = DandyInventorySync.call
    puts "[ops:sync] 產品庫存表: #{inventory[:error] || 'ok'}"

    failures = dept.count { |_, r| r[:error] } + (annual[:error] ? 1 : 0) + (inventory[:error] ? 1 : 0)
    abort("[ops:sync] #{failures} source(s) failed") if failures.positive?
  end

  # Render Cron Job：每天台北 07:30（UTC 23:30，cron "30 23 * * *"）
  # command: bundle exec rake ops:sync ops:briefing —— 先抓最新日誌再生成晨報
  desc "生成今日 AI 晨報（讀部門日誌＋行事曆，落地 daily_briefings）"
  task briefing: :environment do
    briefing = DailyBriefingService.call
    if briefing.status == "success"
      puts "[ops:briefing] #{briefing.briefing_date}: summary=#{briefing.summary.size} " \
           "dropped=#{briefing.dropped_balls.size} pending=#{briefing.pending_decisions.size}"
    else
      abort("[ops:briefing] FAILED: #{briefing.error_message}")
    end
  end
end

# frozen_string_literal: true

# 營運資料同步（給 Render Cron Job 用；本機也可手動跑）。
# Render 設定：Cron Job 服務 → command: bundle exec rake ops:sync
# 建議排程：每小時（"0 * * * *"，UTC）。頁面上的背景同步保留為備援。
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

    # 只在 DANDY 表同步成功時才套用到 crm_products，避免拿舊快照的過期資料覆蓋。
    product_sync = inventory[:error].nil? ? CrmProductInventorySync.call : { error: "skipped (dandy sync failed)" }
    if product_sync[:error]
      puts "[ops:sync] crm_products 庫存狀態同步: #{product_sync[:error]}"
    else
      puts "[ops:sync] crm_products 庫存狀態同步: 更新 #{product_sync[:updated].size} 項" \
           "#{product_sync[:unmapped_names].any? ? "，未對應品名：#{product_sync[:unmapped_names].join('、')}" : ''}"
    end

    failures = dept.count { |_, r| r[:error] } + (annual[:error] ? 1 : 0) + (inventory[:error] ? 1 : 0) +
               (product_sync[:error] && inventory[:error].nil? ? 1 : 0)
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

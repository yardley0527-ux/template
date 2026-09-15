# frozen_string_literal: true
#
# 每週經營決策報告。Render 設定：Cron Job 服務 → command:
#   bundle exec rake ops:weekly_briefing
# 建議排程：每週一台北 08:00（UTC 週一 00:00，cron "0 0 * * 1"）。
#
# 跟 ops:sync/ops:briefing 分開的 namespace 底下的獨立 task，因為依賴的來源
# 資料不同（customer_purchase_summaries／livestreams／crm_customer_product_cycles）。
# 實際的「先刷新快取、再產生報告」邏輯統一放在 WeeklyBriefingRunner，跟
# WeeklyBriefingsController#regenerate 共用同一份——2026-09-15 之前這裡跟
# controller 各自維護一份刷新邏輯，controller 那份漏刷 crm_customer_product_cycles，
# 是「商品回購全部為0」的根因，統一之後不會再出現這種分岔。
#
# 排程一律強制刷新（force_refresh: true），不管快取看起來新不新鮮，確保
# 每週固定跑一次完整重算。手動補跑／測試：
#   bin/rails ops:weekly_briefing
#   WEEK=2026-09-08 bin/rails ops:weekly_briefing   # 指定週一日期補算某一週
namespace :ops do
  desc "刷新每週報告依賴的分析快取，再產生本週經營決策報告"
  task weekly_briefing: :environment do
    week_start = ENV["WEEK"].presence ? Date.parse(ENV["WEEK"]) : Date.current

    briefing, refresh_log = WeeklyBriefingRunner.call(week_start: week_start, force_refresh: true)
    refresh_log.each { |k, v| puts "[ops:weekly_briefing] #{k}: #{v}" }

    if briefing.status == "success"
      puts "[ops:weekly_briefing] #{briefing.week_start}~#{briefing.week_end}: " \
           "status=#{briefing.business_status_label} decisions=#{briefing.decisions.size} " \
           "risks=#{briefing.risk_flags.size} todos=#{briefing.todos.count}"
    else
      abort("[ops:weekly_briefing] FAILED: #{briefing.error_message}")
    end
  end
end

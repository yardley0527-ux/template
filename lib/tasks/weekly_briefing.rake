# frozen_string_literal: true
#
# 每週營運檢討報告。Render 設定：Cron Job 服務 → command:
#   bundle exec rake ops:weekly_briefing
# 建議排程：每週一台北 08:00（UTC 週一 00:00，cron "0 0 * * 1"）。
#
# 跟 ops:sync/ops:briefing 分開的 namespace 底下的獨立 task，因為依賴的來源
# 資料不同（customer_purchase_summaries／livestreams／crm_customer_product_cycles），
# 不共用同一支 cron。手動補跑／測試可直接下：
#   bin/rails ops:weekly_briefing
#   WEEK=2026-09-08 bin/rails ops:weekly_briefing   # 指定週一日期補算某一週
namespace :ops do
  desc "刷新每週報告依賴的分析快取，再產生本週營運檢討報告"
  task weekly_briefing: :environment do
    week_start = ENV["WEEK"].presence ? Date.parse(ENV["WEEK"]) : Date.current

    puts "[ops:weekly_briefing] refreshing customer_purchase_summaries..."
    CustomerPurchaseSummaryRefreshService.call

    puts "[ops:weekly_briefing] refreshing livestream stats..."
    LivestreamStatsRefreshService.call

    puts "[ops:weekly_briefing] refreshing crm_customer_product_cycles..."
    CrmProduct.confirmed
              .where.not(key: CrmRepurchaseCycleConfigSeedService::EXCLUDED_PRODUCT_KEYS)
              .order(:id).pluck(:key).each do |key|
      CrmCustomerProductCycleBuilderService.call(product_key: key)
    end

    briefing = WeeklyBriefingService.call(week_start: week_start)
    if briefing.status == "success"
      puts "[ops:weekly_briefing] #{briefing.week_start}~#{briefing.week_end}: " \
           "wins=#{briefing.wins.size} issues=#{briefing.issues.size} " \
           "risks=#{briefing.risks.size} todos=#{briefing.todos.count}"
    else
      abort("[ops:weekly_briefing] FAILED: #{briefing.error_message}")
    end
  end
end

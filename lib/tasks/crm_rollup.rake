# lib/tasks/crm_rollup.rake
# frozen_string_literal: true
#
# Rollup Phase 2D — unified CLI entry point that runs the 3 existing rollup
# services (tracking -> daily stats -> monthly stats) in sequence, either for
# one product or for every product in JourneyProducts::PRODUCTS.
#
# Rake-only by design: GoodJob / queue backend is still ON HOLD, and a rake
# task can be invoked directly from a system cron or hosting-platform
# scheduler without depending on that decision.
#
# Runner 本體在 lib/crm_rollup_runner.rb（明確 require，不進 autoload 路徑）。
# refresh_all 會寫一筆 SyncRun(source: "crm_rollup") 供首頁 sync_alerts 監控。

require Rails.root.join("lib/crm_rollup_runner") if defined?(Rails)

namespace :crm_rollup do
  desc <<~DESC
    Refresh tracking -> daily stats -> monthly stats for one product, in order.
    Any step failing aborts this product's remaining steps and raises (exit code != 0).

    Usage:
      bin/rails "crm_rollup:refresh[omnipotent]"
      STAT_DATE=2026-06-20 STAT_MONTH=2026-06-01 bin/rails "crm_rollup:refresh[omnipotent]"
  DESC
  task :refresh, [:product_key] => :environment do |_t, args|
    runner = CrmRollupRunner.new(
      stat_date:  CrmRollupRunner.parse_stat_date,
      stat_month: CrmRollupRunner.parse_stat_month
    )
    runner.run_product(args[:product_key])
  end

  desc <<~DESC
    Refresh tracking -> daily stats -> monthly stats for every product in
    JourneyProducts::PRODUCTS. One product failing does not stop the others,
    but the task exits non-zero if any product failed.

    Usage:
      bin/rails crm_rollup:refresh_all
      STAT_DATE=2026-06-20 STAT_MONTH=2026-06-01 bin/rails crm_rollup:refresh_all
  DESC
  task refresh_all: :environment do
    runner = CrmRollupRunner.new(
      stat_date:  CrmRollupRunner.parse_stat_date,
      stat_month: CrmRollupRunner.parse_stat_month
    )
    runner.run_all
  end
end

# frozen_string_literal: true
#
# Restores rows deleted by a specific shopline_orders:dedupe_pattern_a
# APPLY=1 run, from shopline_orders_dedupe_backups. Always scoped to exactly
# one RUN_ID (the dedupe_run_id printed by that run, or found via
# `ShoplineOrdersDedupeBackup.distinct.pluck(:dedupe_run_id)`). Dry-run by
# default; nothing is ever restored unless APPLY=1.
#
#   RUN_ID=<uuid> bin/rails shopline_orders:restore_dedupe_run
#   RUN_ID=<uuid> APPLY=1 bin/rails shopline_orders:restore_dedupe_run
#
# After a restore APPLY, run `bin/rails shopline_orders:rehash_content_ids
# APPLY=1` next — restored rows get a placeholder hash and will not be
# matched by a future import until rehash gives them their real one (see
# ShoplineOrdersRestoreService for why).

require Rails.root.join("lib/shopline_orders_restore_runner") if defined?(Rails)

namespace :shopline_orders do
  desc "Restore a specific dedupe run's deleted rows from backup. Requires RUN_ID. Dry-run unless APPLY=1."
  task restore_dedupe_run: :environment do
    run_id = ENV["RUN_ID"]
    if run_id.blank?
      puts "[shopline_orders:restore_dedupe_run] RUN_ID is required. " \
           "Available: #{ShoplineOrdersDedupeBackup.distinct.pluck(:dedupe_run_id)}"
      next
    end

    if ENV["APPLY"] == "1"
      ShoplineOrdersRestoreRunner.apply(dedupe_run_id: run_id)
    else
      ShoplineOrdersRestoreRunner.dry_run(dedupe_run_id: run_id)
    end
  end
end

# frozen_string_literal: true
#
# One-time migration: recompute source_row_hash for all shopline_orders rows
# with the new content_hash formula (total_amount removed, occurrence added).
# REQUIRED before deploying the updated PaidOrdersWorkbookImporter against a
# database whose hashes still use the old formula — see
# ShoplineOrdersRehashService for the full reasoning.
#
#   bin/rails shopline_orders:rehash_content_ids            # dry-run (default)
#   APPLY=1 bin/rails shopline_orders:rehash_content_ids     # writes
#
# apply takes the shared ShoplineOrdersMaintenanceLock (also used by the
# importer and by ShoplineOrdersDedupeService) and refuses to write if a
# fresh collision check finds anything — see ShoplineOrdersRehashRunner for
# the SyncRun(source: "shopline_orders_rehash") lifecycle this leaves behind.

require Rails.root.join("lib/shopline_orders_rehash_runner") if defined?(Rails)

namespace :shopline_orders do
  desc "Recompute source_row_hash with the new content_hash formula. Dry-run unless APPLY=1."
  task rehash_content_ids: :environment do
    if ENV["APPLY"] == "1"
      ShoplineOrdersRehashRunner.apply
    else
      ShoplineOrdersRehashRunner.dry_run
    end
  end
end

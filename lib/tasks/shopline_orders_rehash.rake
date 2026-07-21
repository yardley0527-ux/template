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

namespace :shopline_orders do
  desc "Recompute source_row_hash with the new content_hash formula. Dry-run unless APPLY=1."
  task rehash_content_ids: :environment do
    apply = ENV["APPLY"] == "1"
    result = ShoplineOrdersRehashService.call(apply: apply)

    puts "[shopline_orders:rehash_content_ids] mode=#{apply ? 'APPLY' : 'DRY_RUN'} " \
         "total_rows=#{result[:total_rows]} rows_to_rehash=#{result[:rows_to_rehash]}"
    puts "[shopline_orders:rehash_content_ids] no changes needed" if result[:rows_to_rehash].zero?
    puts "[shopline_orders:rehash_content_ids] re-run with APPLY=1 to write" unless apply
  end
end

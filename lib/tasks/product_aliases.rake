# lib/tasks/product_aliases.rake
# frozen_string_literal: true
#
# Epic E1 — Product Alias Registry rake tasks.
#
# Usage:
#   DRY_RUN=true  bin/rails product_aliases:generate_regex   # preview only
#                 bin/rails product_aliases:generate_regex   # apply changes

namespace :product_aliases do
  desc "Regenerate crm_products.regex_pattern from active aliases. DRY_RUN=true to preview."
  task generate_regex: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV["DRY_RUN"])
    sep     = "=" * 70

    puts sep
    puts " Product Aliases → Regex Generator#{dry_run ? ' [DRY RUN — no DB writes]' : ''}"
    puts sep

    result  = ProductAliasRegexGeneratorService.call(dry_run: dry_run)
    summary = result[:summary]
    log     = result[:log]

    puts "\n── Results ──────────────────────────────────────────────────────────"
    log.each do |entry|
      icon = case entry[:action]
             when :update           then "  [UPDATE]    "
             when :skip_unchanged   then "  [SKIP]      "
             when :skip_no_aliases  then "  [NO ALIAS]  "
             end
      puts "#{icon} #{entry[:key].ljust(22)} #{entry[:detail]}"
    end

    puts "\n── Summary ──────────────────────────────────────────────────────────"
    puts "  Updated                 : #{summary[:updated]}"
    puts "  Skipped (unchanged)     : #{summary[:skipped_unchanged]}"
    puts "  Skipped (no aliases)    : #{summary[:skipped_no_aliases]}"

    puts "\n── Next Steps ───────────────────────────────────────────────────────"
    if dry_run
      puts "  Re-run without DRY_RUN=true to apply regex updates."
      puts "  Then re-run: ProductNameMappingReviewReportService.call"
      puts "  to confirm bundle detection is correct."
    else
      puts "  1. Re-run ProductNameMappingReviewReportService.call to verify"
      puts "     bundle_candidate and single_product_regex_confirmable buckets."
      puts "  2. Proceed with Bulk Confirm when review is complete."
    end
    puts sep
  end
end

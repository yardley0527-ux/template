# lib/tasks/product_registry.rake
# frozen_string_literal: true
#
# Epic B2-2A — Product Candidate Generator.
#
# Scans ShoplineOrder.product_name and LivestreamProduct.name, seeds the
# known product_keys (JourneyProducts::PRODUCTS + probiotic) into
# crm_products, and refreshes the candidate suggestions in
# product_name_mappings for the Product Registry Review UI.
#
# Safe to rerun any time (e.g. after every order re-import) — never
# overwrites a row a reviewer has already confirmed/assigned/ignored.
#
# Usage:
#   bin/rails product_registry:generate_candidates
#   DRY_RUN=true bin/rails product_registry:generate_candidates

namespace :product_registry do
  desc "Seed known product_keys and refresh product_name_mappings candidates (preview-safe, idempotent)"
  task generate_candidates: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV["DRY_RUN"])

    summary = ProductCandidateGeneratorService.call(dry_run: dry_run)

    puts "[product_registry] dry_run=#{dry_run}"
    summary.each { |key, count| puts "[product_registry] #{key}=#{count}" }
  end

  desc "Bootstrap: seed all 13 CrmProducts + patterns + mapping candidates. Idempotent. DRY_RUN=true to preview."
  task bootstrap: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV["DRY_RUN"])
    sep     = "=" * 70

    puts sep
    puts " Product Registry Bootstrap#{dry_run ? ' [DRY RUN — no DB writes]' : ''}"
    puts sep

    result  = ProductRegistryBootstrapService.call(dry_run: dry_run)
    summary = result[:summary]
    log     = result[:log]

    puts "\n── Phase 1: CrmProducts (#{ProductRegistryBootstrapService::ALL_PRODUCTS.size} total) ──────────────────────────"
    log.each do |entry|
      icon = case entry[:action]
             when :create   then "  [CREATED]    "
             when :backfill then "  [BACKFILLED] "
             when :skip     then "  [SKIP]       "
             end
      puts "#{icon} #{entry[:key].ljust(22)} #{entry[:detail]}"
    end

    puts "\n── Phase 1 Summary ──────────────────────────────────────────────────"
    puts "  Created            : #{summary[:created]}"
    puts "  Patterns backfilled: #{summary[:patterns_backfilled]}"
    puts "  Skipped (complete) : #{summary[:skipped]}"

    unless dry_run
      puts "\n── Phase 2: ProductNameMappings ─────────────────────────────────────"
      puts "  Mappings created   : #{summary[:mappings_created]}"
      puts "  Mappings updated   : #{summary[:mappings_updated]}"
      puts "  Suggestions written: #{summary[:suggestions_written]}"

      puts "\n── Verification ─────────────────────────────────────────────────────"
      total     = CrmProduct.for_analysis.count
      pending   = ProductNameMapping.pending.count
      confirmed = ProductNameMapping.confirmed.count
      puts "  CrmProduct.for_analysis      : #{total} (expected: 13)"
      puts "  ProductNameMappings pending  : #{pending}"
      puts "  ProductNameMappings confirmed: #{confirmed}"
      status = total == 13 ? "OK" : "WARNING: expected 13, got #{total}"
      puts "  Status: #{status}"
    end

    puts "\n── Next Steps ───────────────────────────────────────────────────────"
    if dry_run
      puts "  Re-run without DRY_RUN=true to apply changes."
    else
      puts "  1. Visit /product_registry to review pending mappings"
      puts "  2. Confirm key SKUs as confirmed_alias"
      puts "  3. bin/rails bundle_components:dry_run"
      puts "  4. bin/rails bundle_components:write"
    end
    puts sep
  end
end

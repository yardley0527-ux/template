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
end

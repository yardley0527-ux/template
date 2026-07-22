# frozen_string_literal: true

# Read-only reconciliation report between the DANDY inventory snapshot and
# crm_products. Writes nothing — see DandyInventoryReconciliationService.
#
#   bundle exec rake ops:dandy_inventory_reconciliation

namespace :ops do
  desc "Read-only report: DANDY inventory snapshot rows vs crm_products mapping"
  task dandy_inventory_reconciliation: :environment do
    result = DandyInventoryReconciliationService.call

    if result.snapshot_date.nil?
      puts "[dandy_inventory_reconciliation] no DandyInventorySnapshot found"
      next
    end

    puts "[dandy_inventory_reconciliation] snapshot_date=#{result.snapshot_date}"
    puts "  mapped (#{result.mapped.size}):"
    result.mapped.each { |m| puts "    #{m[:dandy_name]} -> #{m[:crm_key]} (realtime=#{m[:realtime]})" }

    puts "  unmapped DANDY rows (#{result.unmapped_dandy_rows.size}, not one of the 13 crm_products):"
    result.unmapped_dandy_rows.each { |u| puts "    #{u[:dandy_name]} (realtime=#{u[:realtime]})" }

    puts "  crm_products with no row in this snapshot (#{result.products_without_dandy_row.size}):"
    result.products_without_dandy_row.each { |k| puts "    #{k}" }

    if result.duplicate_targets.any?
      puts "  DUPLICATE TARGETS (#{result.duplicate_targets.size}) — more than one DANDY row mapped to the same product:"
      result.duplicate_targets.each { |d| puts "    #{d[:crm_key]}: #{d[:dandy_names].join(', ')}" }
    end
  end
end

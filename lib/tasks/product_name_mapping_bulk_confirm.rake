# lib/tasks/product_name_mapping_bulk_confirm.rake
# frozen_string_literal: true
#
# Epic E2-3 — Bulk Confirm Workflow.
#
# Usage:
#   DRY_RUN=true bundle exec rails product_name_mappings:bulk_confirm   # preview only
#                bundle exec rails product_name_mappings:bulk_confirm   # apply changes
#
# Optional: PERFORMED_BY_USER_ID=<id> to attribute the confirms/history to a user.

namespace :product_name_mappings do
  desc "Bulk confirm single_product_regex_confirmable mappings. DRY_RUN=true to preview."
  task bulk_confirm: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV["DRY_RUN"])
    performed_by_user_id = ENV["PERFORMED_BY_USER_ID"].presence&.to_i
    sep = "=" * 70

    puts sep
    puts " Bulk Confirm#{dry_run ? ' Preview [DRY RUN — no DB writes]' : ''}"
    puts sep

    if dry_run
      result = ProductNameMappingBulkConfirmService.call(dry_run: true)

      puts "\n總共："
      puts "  #{result[:total]} mappings"

      puts "\n依產品分類："
      result[:by_product].sort_by { |_, count| -count }.each do |label, count|
        puts "  #{label}："
        puts "  #{count}"
      end

      puts "\nTop 30 mappings："
      result[:top_30].each do |row|
        puts "  #{row[:raw_name].ljust(30)} → #{row[:suggested_crm_product]} (x#{row[:occurrence_count]})"
      end

      puts "\n── Next Steps ───────────────────────────────────────────────────────"
      puts "  Re-run without DRY_RUN=true to apply confirms."
    else
      result = ProductNameMappingBulkConfirmService.call(
        dry_run:              false,
        performed_by_user_id: performed_by_user_id
      )

      puts "\n── Summary ──────────────────────────────────────────────────────────"
      puts "  Confirmed        : #{result[:confirmed_count]}"
      puts "  Skipped          : #{result[:skipped_count]}"
      puts "  History written  : #{result[:history_written]}"

      puts "\n  依產品分類："
      result[:by_product].sort_by { |_, count| -count }.each do |label, count|
        puts "    #{label}：#{count}"
      end
    end
    puts sep
  end
end

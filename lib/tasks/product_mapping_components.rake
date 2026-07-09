# lib/tasks/product_mapping_components.rake
# frozen_string_literal: true
#
# Epic E3-3 — write ProductMappingComponent rows from the quantity parser.
#
# Usage:
#   DRY_RUN=true bundle exec rails product_mapping_components:write_from_parser   # preview only
#                bundle exec rails product_mapping_components:write_from_parser   # apply
#
# Additive only: mappings that already have components (Epic C rows) are
# skipped untouched — reconciliation of those is E3-4, not this task.

namespace :product_mapping_components do
  desc "Write components for confirmed mappings from ProductQuantityParserService. DRY_RUN=true to preview."
  task write_from_parser: :environment do
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV["DRY_RUN"])
    sep = "=" * 70

    puts sep
    puts " Component Writer — E3-3#{dry_run ? ' [DRY RUN — no DB writes]' : ''}"
    puts sep

    result = ProductMappingComponentWriterService.call(dry_run: dry_run)

    puts "\n總共："
    puts "  Confirmed mappings scanned : #{result[:total_confirmed]}"
    puts "  Parsed                     : #{result[:parsed_count]}"
    puts "  Unparsed (skip)            : #{result[:unparsed_count]}"
    puts "  Already has components     : #{result[:already_has_components_count]}"
    puts "  Overlap ambiguous (failed) : #{result[:failed_overlap_count]}"
    puts "  Would write                : #{result[:would_write_count]}"

    if result[:failed_overlap_raw_names].any?
      puts "\nOverlap ambiguous（regex span 重疊，拒絕寫入，需人工檢查）："
      result[:failed_overlap_raw_names].each { |n| puts "  #{n}" }
    end

    puts "\n依產品分類（would-write）："
    result[:by_product].sort_by { |_, v| -v[:rows] }.each do |label, v|
      puts "  #{label}：#{v[:rows]} rows（paid 合計 #{v[:paid]}、gift 合計 #{v[:gift]}）"
    end

    puts "\nTop #{ProductMappingComponentWriterService::TOP_ROWS} would-write rows："
    result[:top_rows].each do |row|
      puts "  #{row[:raw_name].inspect}"
      row[:components].each do |c|
        puts "      #{c[:crm_product_label]} (#{c[:crm_product_key]})  paid=#{c[:paid_quantity]} gift=#{c[:gift_quantity]} total=#{c[:total_quantity]}"
      end
    end

    puts "\n#{sep}"
    if dry_run
      puts " DB writes: 0 — re-run without DRY_RUN=true to apply."
    else
      puts " Written mappings : #{result[:written_mappings]}"
      puts " Component rows   : #{result[:created_rows]}"
      puts " 驗證：bundle exec rails product_name_mappings:quantity_parser_dry_run"
      puts " （would-write 應歸零、already_has_components 應等於上面 Written mappings + 既有 Epic C 筆數）"
    end
    puts sep
  end
end

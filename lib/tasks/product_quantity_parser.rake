# lib/tasks/product_quantity_parser.rake
# frozen_string_literal: true
#
# Epic E3-2 — Quantity/Promotion Parser, dry-run only.
#
# Usage:
#   bundle exec rails product_name_mappings:quantity_parser_dry_run
#
# This task NEVER writes to the database — ProductQuantityParserService and
# ProductQuantityParserDryRunReportService are both read-only. Writing
# product_mapping_components is E3-3/E3-4, not this task.

namespace :product_name_mappings do
  desc "Dry-run report: parse quantity/gift split for all confirmed mappings, diff against existing components. Read-only."
  task quantity_parser_dry_run: :environment do
    sep = "=" * 70

    puts sep
    puts " Quantity Parser — Dry Run Report [READ ONLY — no DB writes]"
    puts sep

    result = ProductQuantityParserDryRunReportService.call

    puts "\n總共："
    puts "  Confirmed mappings scanned      : #{result[:total_confirmed]}"
    puts "  Parser found 0 components       : #{result[:total_unparsed]}"
    puts "  Already has components (Epic C) : #{result[:already_componented]}"

    if result[:unparsed_raw_names].any?
      puts "\n無法解析（parser 找不到任何產品匹配，需要人工檢查）："
      result[:unparsed_raw_names].first(30).each { |n| puts "  #{n}" }
      remaining = result[:unparsed_raw_names].size - 30
      puts "  ...還有 #{remaining} 筆" if remaining.positive?
    end

    puts "\n新舊 parser 差異（既有 #{result[:already_componented]} 筆 mapping 中）："
    puts "  總差異數        : #{result[:diffs].size}"
    puts "  含「送/贈」差異 : #{result[:diffs_with_promotion].size}"

    if result[:diffs].any?
      puts "\n差異明細（[送/贈] 標記代表 raw_name 含促銷字元，最可能是舊 parser 誤判贈品為付費品）："
      result[:diffs].each do |d|
        marker = d[:contains_promotion_marker] ? "[送/贈]" : "       "
        puts "  #{marker} #{d[:raw_name].inspect}"
        puts "         舊（Epic C）: #{d[:old_state].inspect}"
        puts "         新（E3）    : #{d[:new_state].inspect}"
      end
    end

    puts "\nTop 30 已成功解析（依 component 數排序，供人工抽查）："
    result[:sample_parsed].each do |r|
      puts "  #{r[:raw_name].inspect}"
      r[:components].each do |c|
        puts "      #{c[:crm_product_label]} (#{c[:crm_product_key]})  paid=#{c[:paid_quantity]} gift=#{c[:gift_quantity]} total=#{c[:total_quantity]}"
      end
    end

    puts "\n#{sep}"
    puts " DB writes: 0 — this is a report only. Writing components is E3-3/E3-4."
    puts sep
  end
end

# frozen_string_literal: true
#
# Shadow Mode（唯讀）：比較現行 rollup 瓶數邏輯與候選折疊規則。
# 不寫任何資料表；輸出只有統計數字，不含 email／姓名。
#
#   bin/rails bottle_folding:shadow_report
#   PRODUCT=metabolism,qingxian bin/rails bottle_folding:shadow_report

namespace :bottle_folding do
  desc "DRY RUN: compare current bottle parsing vs candidate folding rules — no DB writes"
  task shadow_report: :environment do
    keys = ENV["PRODUCT"].presence&.split(",") || JourneyProducts::PRODUCTS.keys

    keys.each do |key|
      report  = BottleFoldingShadowReport.call(product_key: key)
      summary = report[:summary]

      puts "== #{key} (extractor_regex_present=#{report[:extractor_regex_present]})"
      puts "   rows=#{summary[:total_rows]} changed=#{summary[:changed_rows]} " \
           "high_value_affected=#{summary[:high_value_affected]}"
      puts "   reasons: #{summary[:reason_counts]}"
      puts "   expected_return_date shift: #{summary[:shift_distribution]}"
      puts "   bucket moves: #{summary[:bucket_moves]}"
    end
  end
end

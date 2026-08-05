# lib/tasks/crm_repurchase_cycles.rake
# frozen_string_literal: true
#
# Phase 1：顧客 × 產品 × 購買週期 資料層。跟 crm_rollup（tracking/daily/monthly
# 快照）是不同的資料表與用途，刻意分開的 namespace，不共用 runner。

namespace :crm_repurchase_cycle_configs do
  desc "冪等 seed：13 個旅程管理產品（排除面膜）的回購週期天數設定"
  task seed: :environment do
    CrmRepurchaseCycleConfigSeedService.call
    puts "done. #{CrmRepurchaseCycleConfig.count} config rows total."
  end
end

namespace :crm_customer_product_cycles do
  desc <<~DESC
    Refresh 顧客×產品×購買週期 for one product, or all 13 tracked products.

    Usage:
      bin/rails "crm_customer_product_cycles:refresh[omnipotent]"
      bin/rails crm_customer_product_cycles:refresh_all
  DESC
  task :refresh, [:product_key] => :environment do |_t, args|
    result = CrmCustomerProductCycleBuilderService.call(product_key: args[:product_key])
    puts "#{args[:product_key]}: #{result}"
  end

  task refresh_all: :environment do
    product_keys = CrmProduct.confirmed
      .where.not(key: CrmRepurchaseCycleConfigSeedService::EXCLUDED_PRODUCT_KEYS)
      .order(:id).pluck(:key)

    product_keys.each do |key|
      result = CrmCustomerProductCycleBuilderService.call(product_key: key)
      puts "#{key}: #{result}"
    end
  end

  desc "唯讀資料品質報告：無法辨識產品/數量/週期的訂單"
  task data_quality_report: :environment do
    report = CrmCustomerProductCycleDataQualityReportService.call
    puts "window_days: #{report[:window_days]}"
    %i[unrecognized_product ambiguous_quantity missing_cycle_config].each do |key|
      section = report[key]
      puts "\n#{key}: #{section[:count]} 筆"
      section[:sample].each { |r| puts "  #{r}" }
    end
  end
end

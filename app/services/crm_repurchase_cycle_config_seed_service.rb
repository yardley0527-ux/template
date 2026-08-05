# frozen_string_literal: true

# 冪等 seed：把 13 個旅程管理產品（confirmed CrmProduct，排除面膜）的回購週期
# 設定寫進 CrmRepurchaseCycleConfig。
#
# - 已在 JourneyProducts::PRODUCTS 有 medians 的 8 個產品：直接沿用那份手工
#   維護的資料（標記 source: legacy_journey_products），不重新計算——避免跟
#   舊 Restock 頁面顯示的天數兜不起來。
# - 其餘產品：用 RepurchaseCycleMedianCalculator 從歷史有效訂單計算。樣本數
#   不足的瓶數桶（含目前歷史資料幾乎是 0 的新產品，例如冰晶番茄）不會寫入
#   任何一列，而不是硬塞一個不可靠的數字——之後由
#   CrmCustomerProductCycleDataQualityReportService 列出「無法辨識週期」。
#
# find_or_initialize_by + save! 是 upsert 語意，重複執行只會覆蓋成同樣的值,
# 不會產生重複列或疊加錯誤資料。
class CrmRepurchaseCycleConfigSeedService
  EXCLUDED_PRODUCT_KEYS = %w[mask].freeze

  def self.call
    new.call
  end

  def call
    target_product_keys.each { |key| seed_product(key) }
    true
  end

  private

  def target_product_keys
    CrmProduct.confirmed.where.not(key: EXCLUDED_PRODUCT_KEYS).order(:id).pluck(:key)
  end

  def seed_product(product_key)
    legacy_medians = JourneyProducts::PRODUCTS.dig(product_key, :medians)

    if legacy_medians.present?
      legacy_medians.each do |bottle_count, median_days|
        upsert(product_key, bottle_count, median_days, 0, "legacy_journey_products")
      end
    else
      computed = RepurchaseCycleMedianCalculator.call(product_key: product_key)
      computed.each do |bottle_count, data|
        upsert(product_key, bottle_count, data[:median_days], data[:sample_size], "historical_median")
      end
    end
  end

  def upsert(product_key, bottle_count, median_days, sample_size, source)
    config = CrmRepurchaseCycleConfig.find_or_initialize_by(product_key: product_key, bottle_count: bottle_count)
    config.median_days = median_days
    config.sample_size = sample_size
    config.source      = source
    config.save!
  end
end

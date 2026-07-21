# frozen_string_literal: true

# Extracts the number of bottles/boxes from a raw product_name string.
# Centralises the logic previously duplicated across 6 controllers and services.
#
# Usage:
#   BottleExtractor.call("薑黃3", "turmeric")   # => 3
#   BottleExtractor.call("代謝家庭號", "metabolism") # => 6
#   BottleExtractor.call("全能（3盒）", "omnipotent") # => 3
#   BottleExtractor.call("美白10+1送1", "whitening") # => 12
class BottleExtractor
  BRACKET_PATTERN = /[（(](\d+)[瓶盒]/.freeze
  BONUS_PATTERN   = /送(\d+)/.freeze

  # Substring overrides that cannot be captured by a numeric regex.
  # { product_key => { substring => bottle_count } }
  SUBSTRING_OVERRIDES = {
    "metabolism" => { "家庭號" => 6 }
  }.freeze

  # 方案 B PR4：product_key → 已編譯 Regexp（或 nil）的 process 內快取。
  # crm_products.regex_pattern 是人工審核維護的靜態參考資料，不會在請求
  # 處理期間變動；ProductLivestreamAnalytics 對大量買家逐一呼叫
  # BottleExtractor.call 時（例如 CustomerProductSnapshotService 內每個 email
  # 一次），原本每次都重新 `CrmProduct.find_by(key:)` 造成嚴重 N+1（正式站
  # 1,458 位未回購買家的情境下量到 1,063 次重複查詢、單一頁面請求
  # 2,453 條 SQL、耗時近 6 秒）。快取後同一個 product_key 只查一次。
  REGEX_CACHE = {}

  def self.call(product_name, product_key)
    new(product_key).extract(product_name)
  end

  def initialize(product_key)
    @product_key = product_key
    @regex       = self.class.cached_regex(product_key)
    @overrides   = SUBSTRING_OVERRIDES[@product_key.to_s] || {}
  end

  def self.cached_regex(product_key)
    key = product_key.to_s
    return REGEX_CACHE[key] if REGEX_CACHE.key?(key)

    REGEX_CACHE[key] = build_regex(key)
  end

  def self.build_regex(product_key)
    crm = CrmProduct.find_by(key: product_key)
    return nil unless crm&.regex_pattern.present?

    Regexp.new(crm.regex_pattern)
  rescue RegexpError
    nil
  end

  def extract(product_name)
    return 1 if product_name.blank?

    @overrides.each do |substring, count|
      return count if product_name.include?(substring)
    end

    base = if @regex && (m = product_name.match(@regex))
      m[1].to_i
    elsif (m = product_name.match(BRACKET_PATTERN))
      m[1].to_i
    else
      1
    end

    base + bonus(product_name)
  end

  private

  def bonus(product_name)
    product_name.match(BONUS_PATTERN)&.[](1).to_i || 0
  end
end

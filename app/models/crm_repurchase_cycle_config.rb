# frozen_string_literal: true

# 產品 × 瓶數 → 回購週期天數設定。取代 JourneyProducts::PRODUCTS[:medians] 硬編碼
# hash 成為新系統（CrmCustomerProductCycle）的資料來源；舊 Restock/Journey 頁面
# 繼續讀 JourneyProducts，兩者刻意並存，不動舊頁面。
class CrmRepurchaseCycleConfig < ApplicationRecord
  SOURCES = %w[historical_median manual legacy_journey_products].freeze

  validates :product_key, presence: true
  validates :bottle_count, presence: true,
            numericality: { only_integer: true, greater_than: 0 }
  validates :median_days, presence: true,
            numericality: { only_integer: true, greater_than: 0 }
  validates :sample_size, presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :bottle_count, uniqueness: { scope: :product_key }

  # { bottle_count => median_days } for one product, ascending by bottle_count.
  def self.medians_for(product_key)
    where(product_key: product_key).order(:bottle_count).pluck(:bottle_count, :median_days).to_h
  end

  # 查一次 DB、算一次內插的便利方法。批次處理多個事件時（例如
  # CrmCustomerProductCycleBuilderService 一次處理一個產品的所有購買事件）
  # 請改用 medians_for + interpolate 分開呼叫，只查一次 DB，避免每個事件都
  # 重新查一次造成 N+1（同一類問題見 BottleExtractor::REGEX_CACHE 的註解）。
  def self.expected_days(product_key, bottle_count)
    interpolate(medians_for(product_key), bottle_count)
  end

  # 內插規則與 JourneyProducts/OmnipotentRestockController 現有的
  # expected_days 邏輯完全一致：命中直接回傳；落在兩個已知瓶數級距之間則線性
  # 內插；超出已知範圍則取最近端點的值（不外插）。純函式，不查 DB。
  def self.interpolate(medians, bottle_count)
    return nil if medians.empty?
    return medians[bottle_count] if medians.key?(bottle_count)

    keys = medians.keys.sort
    lo = keys.select { |k| k < bottle_count }.last
    hi = keys.select { |k| k > bottle_count }.first
    return medians[lo || hi] unless lo && hi

    lo_v = medians[lo]
    hi_v = medians[hi]
    (lo_v + (hi_v - lo_v).to_f * (bottle_count - lo) / (hi - lo)).round
  end

  # 加購觀察窗（天）：下一筆同產品訂單落在這個窗口內視為「加購」而非「回購」。
  # Phase 1.5：從 CrmCustomerProductCycleBuilderService 抽出來變成單一可調整
  # 常數，不寫死在 matcher 裡——之後要依產品調整，再改成每個 product_key
  # 各自一個值即可，呼叫端（matcher）不用動。
  ADDON_WINDOW_MIN_DAYS = 3
  ADDON_WINDOW_RATIO    = 0.3

  def self.addon_window_days(expected_days)
    [(expected_days * ADDON_WINDOW_RATIO).round, ADDON_WINDOW_MIN_DAYS].max
  end
end

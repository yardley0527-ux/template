module DailyOrdersHelper
  # 舊客消費金額級距顏色（8000 以下維持原本粉紅字，不回傳顏色）
  AMOUNT_TIER_COLORS = [
    [20_000, "#6f42c1"], # 2 萬含以上：紫
    [15_000, "#fd7e14"], # 1萬5 - 1萬9999：橘
    [8_000,  "#0d6efd"]  # 8000 - 1萬4999：藍
  ].freeze

  def daily_orders_amount_tier_color(amount)
    AMOUNT_TIER_COLORS.find { |threshold, _| amount.to_f >= threshold }&.last
  end
end

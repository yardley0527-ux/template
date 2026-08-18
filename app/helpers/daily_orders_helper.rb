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

  # 舊客總攬用的完成度小卡（傳首購產品訊息／社群部維護訊息／健康資訊卡）
  def daily_orders_gift_tile(icon:, color:, label:, flag:, done:, total:, unit:)
    remaining = total - done
    badge_class = remaining > 0 ? "text-danger" : "text-success"
    badge_text  = remaining > 0 ? "（還有 #{remaining} #{unit}未完成）" : "✓ 全部完成"

    content_tag(:div, class: "d-flex align-items-center px-3 py-2 rounded", style: "background:#f8f9fa; border:1px solid #dee2e6; gap:10px;") do
      safe_join([
        content_tag(:i, "", class: "fal #{icon}", style: "color:#{color}; font-size:1.1rem;"),
        content_tag(:div) do
          safe_join([
            content_tag(:div, label, class: "text-muted", style: "font-size:0.75rem;"),
            content_tag(:div, class: "fw-bold", style: "font-size:1rem;") do
              safe_join([
                content_tag(:span, done, id: "#{flag}-done-count"),
                " / ",
                content_tag(:span, total, id: "#{flag}-total-count"),
                " #{unit} ",
                content_tag(:span, badge_text, id: "#{flag}-badge", class: badge_class, style: "font-size:0.78rem;")
              ])
            end
          ])
        end
      ])
    end
  end
end

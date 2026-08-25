module DailyOrdersHelper
  def daily_orders_ig_link(account)
    return nil if account.blank?

    handle = account.strip.gsub(/^@/, '').gsub(%r{https?://(?:www\.)?instagram\.com/?}, '').gsub(%r{/$}, '').strip
    handle.present? ? "https://www.instagram.com/#{handle}/" : nil
  end

  # 舊客消費金額級距顏色（8000 以下維持原本粉紅字，不回傳顏色）
  AMOUNT_TIER_COLORS = [
    [20_000, "#6f42c1"], # 2 萬含以上：紫
    [15_000, "#fd7e14"], # 1萬5 - 1萬9999：橘
    [8_000,  "#0d6efd"]  # 8000 - 1萬4999：藍
  ].freeze

  def daily_orders_amount_tier_color(amount)
    AMOUNT_TIER_COLORS.find { |threshold, _| amount.to_f >= threshold }&.last
  end

  # 舊客總攬用的完成度小卡（傳首購產品訊息／社群部維護訊息／CRM維護已讀/CRM維護未讀）
  # modal_target 有給值時，整張卡片可點擊，彈出對應 modal（例如已完成名單）
  # remaining_word/done_word 可覆寫預設的「未完成」「全部完成」字樣（例如 CRM維護已讀 用「未讀」）
  def daily_orders_gift_tile(icon:, color:, label:, flag:, done:, total:, unit:, modal_target: nil, remaining_word: "未完成", done_word: "全部完成")
    remaining = total - done
    badge_class = remaining > 0 ? "text-danger" : "text-success"
    badge_text  = remaining > 0 ? "（還有 #{remaining} #{unit}#{remaining_word}）" : "✓ #{done_word}"

    wrapper_style = "background:#f8f9fa; border:1px solid #dee2e6; gap:10px;"
    wrapper_options = { class: "d-flex align-items-center px-3 py-2 rounded" }
    if modal_target
      wrapper_style += " cursor:pointer;"
      wrapper_options["data-toggle"] = "modal"
      wrapper_options["data-target"] = "##{modal_target}"
    end
    wrapper_options[:style] = wrapper_style

    content_tag(:div, wrapper_options) do
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

  # CRM維護未讀專用小卡：單純顯示「X 人未讀」，點擊彈出可直接標記已讀的名單 modal
  # （不用 daily_orders_gift_tile 的完成度 done/total 框架，因為「未讀」不是要追求打勾到底的進度條，
  # 而是一份待處理的行動清單，講「還有幾人未讀」比「未完成 X 筆」更直覺）
  def daily_orders_unread_count_tile(icon:, color:, label:, flag:, count:, modal_target:)
    content_tag(:div, class: "d-flex align-items-center px-3 py-2 rounded", style: "background:#f8f9fa; border:1px solid #dee2e6; gap:10px; cursor:pointer;", "data-toggle" => "modal", "data-target" => "##{modal_target}") do
      safe_join([
        content_tag(:i, "", class: "fal #{icon}", style: "color:#{color}; font-size:1.1rem;"),
        content_tag(:div) do
          safe_join([
            content_tag(:div, label, class: "text-muted", style: "font-size:0.75rem;"),
            content_tag(:div, class: "fw-bold", style: "font-size:1rem;") do
              content_tag(:span, count.positive? ? "#{count} 人未讀" : "✓ 沒有未讀", id: "#{flag}-unread-count", class: count.positive? ? "text-danger" : "text-success")
            end
          ])
        end
      ])
    end
  end
end

# frozen_string_literal: true

module WeeklyBriefingsHelper
  def wb_money(value)
    number_to_currency(value.to_f, unit: "NT$", precision: 0)
  end

  def wb_pct(value)
    return "—" if value.nil?

    "#{number_with_precision(value.to_f, precision: 1)}%"
  end

  def wb_delta_badge(delta_pct)
    return content_tag(:span, "—", class: "text-muted") if delta_pct.nil?

    cls = delta_pct.to_f.positive? ? "badge-success" : (delta_pct.to_f.negative? ? "badge-danger" : "badge-secondary")
    arrow = delta_pct.to_f.positive? ? "▲" : (delta_pct.to_f.negative? ? "▼" : "―")
    content_tag(:span, "#{arrow} #{wb_pct(delta_pct.abs)}", class: "badge #{cls}")
  end

  def wb_priority_badge(priority)
    cls = { "high" => "badge-danger", "medium" => "badge-warning", "low" => "badge-secondary" }.fetch(priority, "badge-secondary")
    label = { "high" => "高", "medium" => "中", "low" => "低" }.fetch(priority, priority)
    content_tag(:span, label, class: "badge #{cls}")
  end
end

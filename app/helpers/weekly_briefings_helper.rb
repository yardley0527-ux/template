# frozen_string_literal: true

module WeeklyBriefingsHelper
  def wb_money(value)
    return "資料不足" if value.nil?

    number_to_currency(value.to_f, unit: "NT$", precision: 0)
  end

  def wb_num(value)
    return "資料不足／計算未完成" if value.nil?

    number_with_delimiter(value)
  end

  def wb_pct(value)
    return "—" if value.nil?

    "#{number_with_precision(value.to_f, precision: 1)}%"
  end

  def wb_delta_badge(delta_pct)
    return content_tag(:span, "資料不足", class: "text-muted small") if delta_pct.nil?

    cls = delta_pct.to_f.positive? ? "badge-success" : (delta_pct.to_f.negative? ? "badge-danger" : "badge-secondary")
    arrow = delta_pct.to_f.positive? ? "▲" : (delta_pct.to_f.negative? ? "▼" : "―")
    content_tag(:span, "#{arrow} #{wb_pct(delta_pct.abs)}", class: "badge #{cls}")
  end

  def wb_priority_badge(priority)
    cls = { "high" => "badge-danger", "medium" => "badge-warning", "low" => "badge-secondary" }.fetch(priority, "badge-secondary")
    label = { "high" => "高", "medium" => "中", "low" => "低" }.fetch(priority, priority)
    content_tag(:span, label, class: "badge #{cls}")
  end

  def wb_severity_badge(severity)
    cls = { "high" => "badge-danger", "medium" => "badge-warning", "low" => "badge-secondary", "data_anomaly" => "badge-dark" }.fetch(severity, "badge-secondary")
    content_tag(:span, WeeklyRiskFlagDetector::SEVERITY_LABELS.fetch(severity, severity), class: "badge #{cls}")
  end

  def wb_status_badge(status)
    cls = {
      "healthy_growth" => "badge-success", "growth_with_concerns" => "badge-info",
      "flat" => "badge-secondary", "short_term_pullback" => "badge-warning",
      "structural_decline" => "badge-danger", "high_risk" => "badge-danger",
      "insufficient_data" => "badge-dark"
    }.fetch(status, "badge-secondary")
    content_tag(:span, WeeklyStatusClassifier::LABELS.fetch(status, status), class: "badge #{cls} p-2")
  end

  def wb_risk_label(flag)
    WeeklyRiskFlagDetector::KEY_LABELS.fetch(flag["key"], flag["key"])
  end

  def wb_evidence_text(evidence)
    return "" if evidence.blank?

    evidence.map { |k, v| "#{k}: #{v}" }.join("　")
  end
end

module HighSpenderFirstPurchaseHelper
  SERIES_COLORS = {
    "代謝錠" => "#3B82F6",
    "薑黃"   => "#F59E0B",
    "全能"   => "#10B981",
    "膠原蛋白"=> "#EC4899",
    "美白"   => "#8B5CF6",
    "蝦紅素" => "#EF4444",
    "清纖粉" => "#06B6D4",
    "魚油"   => "#14B8A6",
    "私密粉" => "#F97316",
    "益生菌" => "#84CC16",
    "穀胱甘肽"=> "#6366F1",
  }.freeze

  # 每個系列的預估回購週期（天）
  SERIES_CYCLE_DAYS = {
    "代謝錠"  => 90,
    "薑黃"    => 90,
    "全能"    => 90,
    "膠原蛋白" => 90,
    "美白"    => 60,
    "清纖粉"  => 60,
    "魚油"    => 90,
    "蝦紅素"  => 90,
    "私密粉"  => 60,
    "益生菌"  => 30,
    "穀胱甘肽" => 90,
    "維DK鈣"  => 90,
  }.freeze

  def hs_series_color(series)
    SERIES_COLORS.fetch(series, "#9ca3af")
  end

  def hs_follow_up_status(customer)
    return { label: "已回購", css: "fp-badge-ok", urgent: false } if customer.purchase_count >= 2

    days_since = (Date.today - customer.first_date.to_date).to_i
    cycle      = SERIES_CYCLE_DAYS.fetch(customer.first_series.to_s, 90)

    if days_since > cycle
      { label: "已超週期", css: "fp-badge-warn",    urgent: true,  days: days_since, cycle: cycle }
    elsif days_since > (cycle * 0.7).to_i
      { label: "接近週期", css: "fp-badge-mid",     urgent: true,  days: days_since, cycle: cycle }
    else
      { label: "待跟進",   css: "fp-badge-neutral", urgent: false, days: days_since, cycle: cycle }
    end
  end
end

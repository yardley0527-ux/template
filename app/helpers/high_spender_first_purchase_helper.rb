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

  def hs_series_color(series)
    SERIES_COLORS.fetch(series, "#9ca3af")
  end
end
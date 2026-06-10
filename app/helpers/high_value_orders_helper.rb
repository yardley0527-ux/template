module HighValueOrdersHelper
  SERIES_COLORS = HighSpenderFirstPurchaseHelper::SERIES_COLORS

  def hvo_series_color(product_name)
    SERIES_COLORS.find { |series, _| product_name.to_s.include?(series) }&.last || "#9ca3af"
  end
end

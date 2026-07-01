# app/helpers/first_purchase_helper.rb
module FirstPurchaseHelper
  # 首購日期是否緊接在某場直播之後（沿用 ProductLivestreamAnalysis 的「事件日~+3天」窗口慣例）
  def nearby_livestream_event(date)
    return nil if date.blank?

    d = date.to_date
    LivestreamAnalysisController::ALL_EVENTS.find { |e| (e[:date]..(e[:date] + 3)).cover?(d) }
  end
end

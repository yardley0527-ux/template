# frozen_string_literal: true

# 行銷機會頁「產生 AI 建議」改背景執行（Claude 回應可能要一兩分鐘），
# 畫面先顯示「產生中」，完成後重新整理就看得到。失敗會寫進 error_message，不影響客群頁。
class MarketingAiSuggestionJob < ApplicationJob
  queue_as :default

  def perform(suggestion_id)
    suggestion = MarketingAiSuggestion.find_by(id: suggestion_id)
    return unless suggestion&.status == "pending"

    Marketing::AiSuggestionService.call(suggestion)
  end
end

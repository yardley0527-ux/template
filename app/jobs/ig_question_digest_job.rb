# frozen_string_literal: true

# /ig_questions「重新整理」按鈕：Claude 要跑一兩分鐘，改背景執行，畫面先顯示「整理中」。
class IgQuestionDigestJob < ApplicationJob
  queue_as :default

  def perform(day)
    Manychat::QuestionDigest.call(Date.parse(day), force: true)
  end
end

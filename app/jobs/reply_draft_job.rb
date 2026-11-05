# frozen_string_literal: true

# 回覆助手：Claude 回應要幾十秒，改背景執行，頁面自動重新整理。
class ReplyDraftJob < ApplicationJob
  queue_as :default

  def perform(draft_id)
    draft = ReplyDraft.find(draft_id)
    result = ReplyAssistant::Answer.call(draft.question)
    # 原文帶入已核准答案不用再核准；AI 新寫的草稿和敏感問題才等人確認。
    direct = result[:match_ref].present? && !result[:needs_human]
    draft.update!(result.merge(status: direct ? "approved" : "pending", final_answer: direct ? result[:answer] : nil, error_message: nil))
  rescue StandardError => e
    draft&.update!(status: "failed", error_message: e.message.truncate(250))
  end
end

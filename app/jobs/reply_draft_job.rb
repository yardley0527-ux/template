# frozen_string_literal: true

# 回覆助手：Claude 回應要幾十秒，改背景執行，頁面自動重新整理。
# 組好的回覆一律等團隊確認（核准後存進知識庫）。
class ReplyDraftJob < ApplicationJob
  queue_as :default

  def perform(draft_id)
    draft = ReplyDraft.find(draft_id)
    result = ReplyAssistant::Answer.call(draft.question)
    draft.update!(result.merge(status: "pending", match_ref: nil, final_answer: nil, error_message: nil))
  rescue StandardError => e
    draft&.update!(status: "failed", error_message: e.message.truncate(250))
  end
end

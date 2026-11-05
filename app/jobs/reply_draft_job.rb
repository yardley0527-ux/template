# frozen_string_literal: true

# 回覆助手：Claude 回應要幾十秒，改背景執行，頁面自動重新整理。
class ReplyDraftJob < ApplicationJob
  queue_as :default

  def perform(draft_id)
    draft = ReplyDraft.find(draft_id)
    draft.update!(ReplyAssistant::Answer.call(draft.question).merge(status: "pending", error_message: nil))
  rescue StandardError => e
    draft&.update!(status: "failed", error_message: e.message.truncate(250))
  end
end

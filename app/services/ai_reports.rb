# frozen_string_literal: true

# 所有打 Claude API 的功能共用的暫停開關：AI 晨報、週報、SEO 日報 LINE 推播、訂單簡報 AI 重點、
# IG 收件匣分類／每日整理／回覆助手、黑金卡客人洞察、行銷 AI 建議。
# 2026-11-17 起暫停：Anthropic API 額度用完（400 credit balance too low），付費前先關掉。
# 要恢復時在 Render 設環境變數 AI_REPORTS_ENABLED=1 即可（不用改程式）。
module AiReports
  PAUSED_NOTE = "AI 報告暫停中（Render 設 AI_REPORTS_ENABLED=1 恢復）"

  # 個別功能可以單獨開：回覆助手設 REPLY_ASSISTANT_ENABLED=1 就能用，其他 AI 功能維持暫停。
  FEATURE_FLAGS = { reply_assistant: "REPLY_ASSISTANT_ENABLED" }.freeze

  def self.paused?(feature = nil)
    return false if feature && ENV[FEATURE_FLAGS.fetch(feature)] == "1"

    ENV["AI_REPORTS_ENABLED"] != "1"
  end
end

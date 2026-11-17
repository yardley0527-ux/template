# frozen_string_literal: true

# 用 Claude API 產生的報告（AI 晨報、週報、SEO 日報 LINE 推播）共用的暫停開關。
# 2026-11-17 起暫停：Anthropic API 額度用完（400 credit balance too low），付費前先關掉。
# 要恢復時在 Render 設環境變數 AI_REPORTS_ENABLED=1 即可（不用改程式）。
module AiReports
  PAUSED_NOTE = "AI 報告暫停中（Render 設 AI_REPORTS_ENABLED=1 恢復）"

  def self.paused?
    ENV["AI_REPORTS_ENABLED"] != "1"
  end
end

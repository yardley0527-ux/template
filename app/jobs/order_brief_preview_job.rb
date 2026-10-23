# frozen_string_literal: true

# 從 /line_bot_groups 按鈕發一份訂單簡報到某個聊天室看樣子（Render Shell 跑太久會自己斷線）。
# 是預覽：不記成「已發送」，不影響匯入訂單後的自動推播。
class OrderBriefPreviewJob < ApplicationJob
  queue_as :default

  def perform(line_bot_group_id, day)
    chat = LineBotGroup.find(line_bot_group_id)
    day = Date.parse(day.to_s)
    report = OrderBrief::Report.new(day)
    line = LineBot::Client.new
    if report.empty?
      line.push_text(chat.group_id, "🧪 #{day} 沒有已付款訂單（可能還沒匯入），沒有訂單簡報可以發")
      return
    end

    messages = [{ type: "text", text: "🧪 測試預覽｜訂單簡報 #{day}" }] +
               OrderBrief::LineDigest.new(day).messages(report, OrderBrief::Highlights.call(report))
    messages.each_slice(LineBot::Client::MAX_MESSAGES) { |batch| line.push_messages(chat.group_id, batch) }
    Rails.logger.info "[OrderBriefPreviewJob] sent #{messages.size} messages to #{chat.name || chat.group_id}"
  rescue StandardError => e
    Rails.logger.error "[OrderBriefPreviewJob] FAILED #{e.class}: #{e.message}"
    LineBot::Client.new.push_text(chat.group_id, "🧪 訂單簡報預覽失敗：#{e.class}: #{e.message.truncate(200)}") if chat
  end
end

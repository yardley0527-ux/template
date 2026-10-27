# frozen_string_literal: true

# /line_bot_groups「立即補發前一天報告」：把這個群組有訂閱的「匯入後」報告補發一次。
# 平常這些報告只在匯入訂單時發，而且同一天只發一次，所以匯入之後才勾選的群組要等到隔天。
# - 那天還沒發過（匯入時沒有群組訂閱）：照正常流程發給所有訂閱群組並記成已發，之後匯入不會重發
# - 那天已經發過：只發給這個群組，不影響其他群組
# 星期一補五～日（同匯入後的自動推播）：訂單簡報一天一份，銷售日報、黑金卡回來合成一份。
class LineReportResendJob < ApplicationJob
  queue_as :default

  DIGESTS = {
    "order_brief" => OrderBrief::LineDigest,
    "sales_daily" => SalesDaily::LineDigest,
    "crm_returns" => CrmReturns::LineDigest
  }.freeze

  attr_writer :line # 測試換成假的 LINE client

  def self.days(today = Date.current)
    yesterday = today - 1
    today.monday? ? (today - 3)..yesterday : yesterday..yesterday
  end

  def perform(line_bot_group_id)
    group = LineBotGroup.find(line_bot_group_id)
    days = self.class.days
    sent = (group.subscriptions & DIGESTS.keys).select do |topic|
      if topic == "order_brief"
        days.map { |day| resend(topic, DIGESTS[topic].new(day, line: line), day, group) }.any?
      else
        resend(topic, DIGESTS[topic].new(days, line: line), days.last, group)
      end
    end
    Rails.logger.info "[LineReportResendJob] #{group.name || group.group_id}: #{sent.inspect}"
    return if sent.any?

    line.push_text(group.group_id, "⚠️ 補發報告：#{label(days)} 沒有可以發的報告（前一天的訂單可能還沒匯入，或黑金卡沒有人回來）")
  rescue StandardError => e
    Rails.logger.error "[LineReportResendJob] FAILED #{e.class}: #{e.message}"
    line.push_text(group.group_id, "⚠️ 補發報告失敗：#{e.class}: #{e.message.truncate(200)}") if group
  end

  private

  def line = @line ||= LineBot::Client.new

  # 回傳這個群組有沒有收到
  def resend(topic, digest, day, group)
    return false unless digest.pushable?

    if LineDigestDelivery.exists?(topic: topic, report_date: day)
      digest.push([group]).positive?
    else
      digest.call.positive?
    end
  end

  def label(days)
    fmt = ->(d) { "#{d.month}/#{d.day}" }
    days.count > 1 ? "#{fmt[days.first]}–#{fmt[days.last]}" : fmt[days.last]
  end
end

# frozen_string_literal: true

# /line_bot_groups「補發報告」：把這個群組有訂閱的「匯入後」報告，選定的日期每天補發一份。
# 平常這些報告只在匯入訂單時發、同一天只發一次：匯入之後才勾選的群組要等隔天，
# 已發過的日期重新匯入（資料更新）也不會再發。這裡讓人自己選日期補發：
# - 那天還沒發過：照正常流程發給所有訂閱群組並記成已發，之後匯入不會重發
# - 那天已經發過：用現在的資料只發給這個群組，不影響其他群組
class LineReportResendJob < ApplicationJob
  queue_as :default

  DIGESTS = {
    "order_brief" => OrderBrief::LineDigest,
    "sales_daily" => SalesDaily::LineDigest,
    "crm_returns" => CrmReturns::LineDigest
  }.freeze
  MAX_DAYS = 7 # 一次最多補幾天，避免選錯範圍把 LINE 額度用完

  attr_writer :line # 測試換成假的 LINE client

  # 預設補哪幾天：星期一補五～日（週末不匯入），其他天補昨天
  def self.default_days(today = Date.current)
    yesterday = today - 1
    today.monday? ? (today - 3)..yesterday : yesterday..yesterday
  end

  # 表單選的日期；不合理（結束早於開始、包含今天以後、超過 MAX_DAYS 天）回傳錯誤訊息字串
  def self.parse_days(from, to, today = Date.current)
    days = Date.parse(from.to_s)..Date.parse(to.to_s)
    return "結束日期不能早於開始日期" if days.first > days.last
    return "只能補發到昨天（今天的訂單還沒完整）" if days.last >= today
    return "一次最多補發 #{MAX_DAYS} 天" if days.count > MAX_DAYS

    days
  rescue Date::Error
    "日期格式不對"
  end

  def perform(line_bot_group_id, from, to)
    group = LineBotGroup.find(line_bot_group_id)
    days = Date.parse(from)..Date.parse(to)
    topics = group.subscriptions & DIGESTS.keys
    sent = days.flat_map { |day| topics.map { |topic| resend(topic, DIGESTS[topic].new(day, line: line), day, group) } }
    Rails.logger.info "[LineReportResendJob] #{group.name || group.group_id} #{days}: #{sent.count(true)} 份"
    return if sent.any?

    line.push_text(group.group_id, "⚠️ 補發報告：#{label(days)} 沒有可以發的報告（訂單可能還沒匯入，或黑金卡沒有人回來）")
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

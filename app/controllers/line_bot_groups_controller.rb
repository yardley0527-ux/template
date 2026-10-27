# frozen_string_literal: true

# 「苼莛小幫手」所在的 LINE 群組，勾選每個群組要收哪些報告。
# 群組本身是小幫手被邀進群組時由 webhook 自動記下的，這頁不新增群組。
# 沒加進任何角色的 page_permissions，限 admin（同 imports）。
class LineBotGroupsController < ApplicationController
  def index
    @groups = LineBotGroup.order(active: :desc, joined_at: :desc)
    @deliveries = LineDigestDelivery.order(report_date: :desc).limit(10)
    @last_error = LineBot::Client.last_error
    if LineBot::Client.configured?
      begin
        @quota = LineBot::Client.new.quota
      rescue LineBot::Client::Error, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
        @quota_error = e.message
      end
    end
  end

  def update
    group = LineBotGroup.find(params[:id])
    group.update!(subscriptions: params.dig(:line_bot_group, :subscriptions) || [])
    redirect_to line_bot_groups_path, notice: "已更新「#{group.name || group.group_id}」的訂閱"
  end

  # 發一份前一天的訂單簡報到這個聊天室看樣子；在背景跑（AI 寫重點＋畫表格約 1–3 分鐘）
  # 只有勾了訂單簡報的群組可以發（其他群組不該收到訂單簡報）
  def preview_order_brief
    group = LineBotGroup.subscribed_to("order_brief").find(params[:id])
    day = Date.current - 1
    OrderBriefPreviewJob.perform_later(group.id, day.iso8601)
    redirect_to line_bot_groups_path, notice: "正在產生 #{day.strftime('%-m/%-d')} 訂單簡報，約 1–3 分鐘後會出現在「#{group.name || group.group_id}」"
  end

  # 補發選定日期的「匯入後」報告（訂單簡報、銷售日報、黑金卡回來，有勾的才發）到這個群組，
  # 每天一份；已發過的日期用現在的資料重發（例如重新匯入更新過的訂單）
  def resend_reports
    group = LineBotGroup.active.find(params[:id])
    days = LineReportResendJob.parse_days(params[:from], params[:to])
    return redirect_to(line_bot_groups_path, alert: "補發失敗：#{days}") if days.is_a?(String)

    LineReportResendJob.perform_later(group.id, days.first.iso8601, days.last.iso8601)
    label = days.count > 1 ? "#{days.first.strftime('%-m/%-d')}–#{days.last.strftime('%-m/%-d')}" : days.last.strftime("%-m/%-d")
    redirect_to line_bot_groups_path, notice: "正在補發 #{label} 的報告到「#{group.name || group.group_id}」，每天一份，約 1–3 分鐘後會出現"
  end
end

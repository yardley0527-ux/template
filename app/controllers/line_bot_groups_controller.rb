# frozen_string_literal: true

# 「苼莛小幫手」所在的 LINE 群組，勾選每個群組要收哪些報告。
# 群組本身是小幫手被邀進群組時由 webhook 自動記下的，這頁不新增群組。
# 沒加進任何角色的 page_permissions，限 admin（同 imports）。
class LineBotGroupsController < ApplicationController
  def index
    @groups = LineBotGroup.order(active: :desc, joined_at: :desc)
    @deliveries = LineDigestDelivery.order(report_date: :desc).limit(10)
  end

  def update
    group = LineBotGroup.find(params[:id])
    group.update!(subscriptions: params.dig(:line_bot_group, :subscriptions) || [])
    redirect_to line_bot_groups_path, notice: "已更新「#{group.name || group.group_id}」的訂閱"
  end
end

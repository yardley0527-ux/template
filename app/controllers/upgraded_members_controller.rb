# frozen_string_literal: true

# 升級名單：彙整 DailyUpgradeMessageListService 每次會員報表匯入後自動記錄的
# 「升級為白卡/銀卡/金卡/黑卡」名單快照，讓營運可以直接在會員管理選單裡看到，
# 不用跟每日商品回購名單混在一起找。實際的名單內容／匯出沿用既有的
# MessageList show／export 頁面，這裡只做彙整與篩選。
class UpgradedMembersController < ApplicationController
  TARGET_LEVELS = %w[白卡 銀卡 金卡 黑卡].freeze

  def index
    @selected_level = TARGET_LEVELS.include?(params[:level].to_s) ? params[:level].to_s : nil

    lists = MessageList.daily_snapshot.where(target_product: TARGET_LEVELS)
    todays_list_ids_by_level = lists.where(sent_on: Date.current).pluck(:target_product, :id).to_h
    @tier_counts = TARGET_LEVELS.index_with do |level|
      list_id = todays_list_ids_by_level[level]
      list_id ? MessageListRecipient.where(message_list_id: list_id).count : 0
    end

    scope = @selected_level ? lists.where(target_product: @selected_level) : lists
    @lists = scope.order(sent_on: :desc, id: :desc).to_a
    @recipient_counts = MessageListRecipient.where(message_list_id: @lists.map(&:id)).group(:message_list_id).count
  end
end

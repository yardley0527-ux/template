# frozen_string_literal: true

# 升級名單：彙整 DailyUpgradeMessageListService 每次會員報表匯入後自動記錄的
# 「升級為白卡/銀卡/金卡/黑卡」名單快照，讓營運可以直接在會員管理選單裡看到，
# 不用跟每日商品回購名單混在一起找。實際的名單內容／匯出沿用既有的
# MessageList show／export 頁面，這裡只做彙整與篩選。
class UpgradedMembersController < ApplicationController
  TARGET_LEVELS = %w[白卡 銀卡 金卡 黑卡].freeze

  # 本週／本月／本年都是「該期間至今」（例如本月＝這個月 1 號到今天），
  # 不是固定往前推 7/30/365 天，符合一般講「本週升了幾個」的直覺。
  PERIODS = {
    "今天" => ->(today) { today..today },
    "本週" => ->(today) { today.beginning_of_week..today },
    "本月" => ->(today) { today.beginning_of_month..today },
    "本年" => ->(today) { today.beginning_of_year..today }
  }.freeze

  def index
    @selected_level = TARGET_LEVELS.include?(params[:level].to_s) ? params[:level].to_s : nil

    all_lists = MessageList.daily_snapshot.where(target_product: TARGET_LEVELS).to_a
    @period_counts = build_period_counts(all_lists)

    # 第一層：月份分頁（"2026-09" 這種 key，畫面上顯示成「2026年9月」）。
    @available_months = all_lists.map { |l| l.sent_on.strftime("%Y-%m") }.uniq.sort.reverse
    @selected_month = @available_months.include?(params[:month].to_s) ? params[:month].to_s : @available_months.first
    lists_in_month = all_lists.select { |l| l.sent_on.strftime("%Y-%m") == @selected_month }

    # 第二層：日期分頁——同一天最多就 4 張卡別的名單，不用再往下列成一長串。
    @available_days = lists_in_month.map(&:sent_on).uniq.sort.reverse
    @selected_day = @available_days.find { |d| d.iso8601 == params[:day].to_s } || @available_days.first
    lists_on_day = lists_in_month.select { |l| l.sent_on == @selected_day }

    # 第三層：卡別篩選（選填）——同一天本來就只有 4 張，篩選只是輔助，不是必要。
    scope = @selected_level ? lists_on_day.select { |l| l.target_product == @selected_level } : lists_on_day
    @lists = scope.sort_by { |l| TARGET_LEVELS.index(l.target_product).to_i }
    @recipient_counts = MessageListRecipient.where(message_list_id: @lists.map(&:id)).group(:message_list_id).count
  end

  private

  # { "今天" => { "白卡" => 3, "銀卡" => 0, ... }, "本週" => {...}, ... }
  def build_period_counts(lists)
    today = Date.current
    lists_by_level = lists.group_by(&:target_product)

    PERIODS.each_with_object({}) do |(label, range_for), out|
      range = range_for.call(today)
      out[label] = TARGET_LEVELS.index_with do |level|
        ids = (lists_by_level[level] || []).select { |l| range.cover?(l.sent_on) }.map(&:id)
        ids.empty? ? 0 : MessageListRecipient.where(message_list_id: ids).count
      end
    end
  end
end

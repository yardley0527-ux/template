# frozen_string_literal: true

# 每週檢討報告待辦事項的操作端點：勾選完成、預覽名單、把可解析的名單條件
# 建立成客服任務。AI 只負責提出 target_query 條件描述，實際名單／建立任務
# 一律由這裡依 CRM 現有資料查詢與既有任務系統（NotificationCustomerTaskService）
# 執行，不吃 AI 生成的 customer id。
class WeeklyBriefingTodosController < ApplicationController
  before_action :set_todo

  def preview
    resolution = WeeklyBriefingTodoTargetResolver.call(@todo.target_query)
    fallback = weekly_briefing_path(week_start: @todo.weekly_briefing.week_start.to_s)

    if resolution[:resolved]
      @todo.update!(target_count: resolution[:count])
      redirect_to fallback, notice: "「#{@todo.title}」符合條件的客戶：#{resolution[:count]} 人"
    else
      redirect_to fallback, alert: "此待辦條件目前無法自動查詢名單，需人工建立名單"
    end
  end

  def toggle
    @todo.done? ? @todo.reopen! : @todo.mark_done!
    redirect_back fallback_location: weekly_briefing_path(week_start: @todo.weekly_briefing.week_start.to_s)
  end

  # 只支援對應到單一產品回購週期的待辦類型（product_overdue／product_due_soon）
  # ——這兩類可以直接掛進既有的 CrmCustomerProductCycle 回購追蹤／客服任務系統。
  # 其他類型（例如跨產品的沉睡會員名單）目前沒有對應的既有任務表可以掛，
  # 只回傳名單供人工後續處理，不勉強塞進不對應的資料模型。
  def create_task
    type = @todo.target_query["type"]
    unless %w[product_overdue product_due_soon].include?(type)
      redirect_back fallback_location: weekly_briefing_path(week_start: @todo.weekly_briefing.week_start.to_s),
                    alert: "此待辦類型（#{type.presence || '未分類'}）沒有對應的既有任務系統，請人工建立名單"
      return
    end

    resolution = WeeklyBriefingTodoTargetResolver.call(@todo.target_query)
    if !resolution[:resolved] || resolution[:count].to_i.zero?
      redirect_back fallback_location: weekly_briefing_path(week_start: @todo.weekly_briefing.week_start.to_s),
                    alert: "查無符合條件的客戶，未建立任務"
      return
    end

    result = NotificationCustomerTaskService.call(
      product_key: @todo.target_query["product_key"],
      emails:      resolution[:emails],
      actor:       current_user.email,
      note:        "來自每週檢討報告待辦：#{@todo.title}"
    )

    redirect_back fallback_location: weekly_briefing_path(week_start: @todo.weekly_briefing.week_start.to_s),
                  notice: "已建立 #{result.created} 筆客服任務（略過 #{result.skipped} 筆已有任務、#{result.no_cycle} 筆查無對應週期）"
  end

  private

  def set_todo
    @todo = WeeklyBriefingTodo.find(params[:id])
  end
end

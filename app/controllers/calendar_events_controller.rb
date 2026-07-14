# frozen_string_literal: true

# 行事曆月曆已搬進首頁（welcome#index），這裡只剩事件的新增/編輯表單與同步動作，
# 操作完一律導回首頁對應月份。
class CalendarEventsController < ApplicationController
  before_action :set_event, only: [:edit, :update, :destroy]

  def sync_departments
    results = DepartmentSheetSync.call
    annual = AnnualCalendarSync.call
    failed = results.select { |_, r| r[:error] }.keys
    failed << "年度行事曆" if annual[:error]
    notice = failed.empty? ? "已同步（部門日誌＋年度行事曆）" : "已同步（失敗：#{failed.join('、')}）"
    redirect_to root_path(month: params[:month]), notice: notice
  end

  def new
    @event = CalendarEvent.new(event_date: params[:date].presence || Date.current)
  end

  def create
    @event = CalendarEvent.new(event_params)
    if @event.save
      redirect_to root_path(month: @event.event_date.strftime("%Y-%m")), notice: "事件已建立"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @event.update(event_params)
      redirect_to root_path(month: @event.event_date.strftime("%Y-%m")), notice: "事件已更新"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @event.destroy
    redirect_to root_path(month: @event.event_date.strftime("%Y-%m")), notice: "事件已刪除"
  end

  private

  def set_event
    @event = CalendarEvent.find(params[:id])
    return unless @event.synced?

    redirect_to root_path(month: @event.event_date.strftime("%Y-%m")),
                alert: "此事件由年度行事曆 Excel 同步，請直接修改 Excel，系統會自動更新"
  end

  def event_params
    permitted = params.require(:calendar_event)
                      .permit(:title, :event_type, :event_date, :time_info, :description, departments: [])
    permitted[:departments] = Array(permitted[:departments]).compact_blank
    permitted
  end
end

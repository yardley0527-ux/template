# frozen_string_literal: true

class CalendarEventsController < ApplicationController
  before_action :set_event, only: [:edit, :update, :destroy]

  def index
    @month = parse_month
    range = @month.beginning_of_month..@month.end_of_month

    events = CalendarEvent.in_range(range).order(:event_date, :created_at).to_a
    events += livestream_record_events(range, events)
    @events_by_date = events.group_by(&:event_date)

    upcoming_range = Date.current..(Date.current + 6)
    upcoming = CalendarEvent.in_range(upcoming_range).order(:event_date, :created_at).to_a
    upcoming += livestream_record_events(upcoming_range, upcoming)
    @upcoming_by_date = upcoming.group_by(&:event_date).sort_by(&:first)
  end

  def new
    @event = CalendarEvent.new(event_date: params[:date].presence || Date.current)
  end

  def create
    @event = CalendarEvent.new(event_params)
    if @event.save
      redirect_to calendar_events_path(month: @event.event_date.strftime("%Y-%m")), notice: "事件已建立"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @event.update(event_params)
      redirect_to calendar_events_path(month: @event.event_date.strftime("%Y-%m")), notice: "事件已更新"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @event.destroy
    redirect_to calendar_events_path(month: @event.event_date.strftime("%Y-%m")), notice: "事件已刪除"
  end

  private

  def set_event
    @event = CalendarEvent.find(params[:id])
  end

  def event_params
    permitted = params.require(:calendar_event)
                      .permit(:title, :event_type, :event_date, :time_info, :description, departments: [])
    permitted[:departments] = Array(permitted[:departments]).compact_blank
    permitted
  end

  def parse_month
    Date.strptime(params[:month], "%Y-%m")
  rescue ArgumentError, TypeError
    Date.current.beginning_of_month
  end

  # 直播歷史（Livestream）已有日期資料，直接帶進行事曆顯示，不用重複輸入。
  # 若同一天已有手動建立的直播事件，就不再重複帶入。
  def livestream_record_events(range, existing_events)
    manual_livestream_dates = existing_events
      .select { |e| e.event_type == "livestream" }
      .map(&:event_date).to_set

    Livestream.unscoped.where(date: range).includes(:livestream_products).filter_map do |ls|
      next if manual_livestream_dates.include?(ls.date)

      products = ls.livestream_products.map { |p| p.name.split(/[（(]/).first.to_s.strip }.reject(&:blank?).uniq
      CalendarEvent.new(
        title:      products.any? ? "直播：#{products.join('、')}" : "直播",
        event_type: "livestream",
        event_date: ls.date,
        description: ls.notes
      )
    end
  end
end

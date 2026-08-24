# frozen_string_literal: true

class CalendarEvent < ApplicationRecord
  EVENT_TYPES = {
    "livestream"       => { label: "直播",         color: "#d9364c" },
    "arrival"          => { label: "產品到貨",     color: "#28a745" },
    "campaign"         => { label: "行銷活動",     color: "#1e6ee8" },
    "holiday"          => { label: "節慶假日",     color: "#f0870f" },
    # livestream_schedule_gap 規則的例外機制：這段期間（event_date..end_date，
    # end_date 為 nil 代表單日）不提醒「太久沒排直播」。
    "livestream_pause" => { label: "直播暫停週期", color: "#8a8a8a" },
    "other"            => { label: "其他",         color: "#6c757d" }
  }.freeze

  DEPARTMENTS = %w[廣告部 編輯部 社群部 CRM 數據部 設計部 物流部].freeze

  validates :title, presence: true
  validates :event_date, presence: true
  validates :event_type, inclusion: { in: EVENT_TYPES.keys }

  scope :in_range, ->(range) { where(event_date: range) }

  # 區間內的事件＋直播歷史（Livestream）虛擬事件：直播紀錄已有日期資料，
  # 直接帶進行事曆顯示，不用重複輸入；同一天已有手動直播事件就不重複帶。
  def self.in_range_with_livestreams(range)
    events = in_range(range).order(:event_date, :created_at).to_a
    manual_livestream_dates = events
      .select { |e| e.event_type == "livestream" }
      .map(&:event_date).to_set

    events + Livestream.unscoped.where(date: range).includes(:livestream_products).filter_map do |ls|
      next if manual_livestream_dates.include?(ls.date)

      products = ls.livestream_products.map { |p| p.name.split(/[（(]/).first.to_s.strip }.reject(&:blank?).uniq
      new(
        title:       products.any? ? "直播：#{products.join('、')}" : "直播",
        event_type:  "livestream",
        event_date:  ls.date,
        description: ls.notes
      )
    end
  end

  # 由年度行事曆 Excel 同步進來的事件（AnnualCalendarSync），
  # 在系統內唯讀，修改要回 Excel 改
  def synced?
    external_key.present?
  end

  def type_label
    EVENT_TYPES.fetch(event_type, EVENT_TYPES["other"])[:label]
  end

  def type_color
    EVENT_TYPES.fetch(event_type, EVENT_TYPES["other"])[:color]
  end
end

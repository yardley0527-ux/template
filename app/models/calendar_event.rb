# frozen_string_literal: true

class CalendarEvent < ApplicationRecord
  EVENT_TYPES = {
    "livestream" => { label: "直播",     color: "#d9364c" },
    "arrival"    => { label: "產品到貨", color: "#28a745" },
    "campaign"   => { label: "行銷活動", color: "#1e6ee8" },
    "holiday"    => { label: "節慶假日", color: "#f0870f" },
    "other"      => { label: "其他",     color: "#6c757d" }
  }.freeze

  DEPARTMENTS = %w[廣告部 編輯部 社群部 CRM 數據部 設計部 物流部].freeze

  validates :title, presence: true
  validates :event_date, presence: true
  validates :event_type, inclusion: { in: EVENT_TYPES.keys }

  scope :in_range, ->(range) { where(event_date: range) }

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

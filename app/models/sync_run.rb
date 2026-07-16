# frozen_string_literal: true

# 每次外部資料同步（部門日誌、年度行事曆）的執行紀錄。
# 同步的可靠性是晨報/戰情面板的前提：失敗必須留下持久紀錄並在頁面上可見，
# 不能只活在 Rails.cache（production 是 per-process memory store，重啟即失憶）。
class SyncRun < ApplicationRecord
  SOURCES = {
    "department_sheets" => "部門日誌",
    "annual_calendar"   => "年度行事曆",
    "dandy_inventory"   => "產品庫存表"
  }.freeze
  STATUSES = %w[running success partial failed].freeze

  validates :source, presence: true, inclusion: { in: SOURCES.keys }
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :finished, -> { where(status: %w[success partial]) }

  def self.latest_for(source)
    where(source: source).order(created_at: :desc).first
  end

  def self.last_finished_at(source)
    finished.where(source: source).maximum(:finished_at)
  end

  # 首頁/行事曆頁顯示用的警告字串；一切正常時回傳空陣列。
  def self.current_alerts
    SOURCES.filter_map do |source, label|
      run = latest_for(source)
      next if run.nil? || run.status == "success" || run.status == "running"

      detail = run.failed_parts.presence&.join("、")
      if run.status == "failed"
        "#{label}同步失敗#{detail ? "（#{detail}）" : ""}"
      else
        "#{label}部分同步失敗#{detail ? "：#{detail}" : ""}"
      end
    end
  end

  # meta 慣例：{ "物流部" => { "dates" => 8, "error" => nil }, ... }
  def failed_parts
    meta.filter_map { |key, value| key if value.is_a?(Hash) && value["error"].present? }
  end
end

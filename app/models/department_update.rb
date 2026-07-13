# frozen_string_literal: true

# 各部門 Google Sheet 工作日誌的每日快照，由 DepartmentSheetSync 同步進來。
class DepartmentUpdate < ApplicationRecord
  # 顯示順序（同步來源見 DepartmentSheetSync::SHEETS）
  DEPARTMENTS = %w[廣告部 編輯部 社群部 CRM 數據部 設計部 物流部 財務部].freeze

  validates :department, presence: true
  validates :log_date, presence: true, uniqueness: { scope: :department }

  scope :in_range, ->(range) { where(log_date: range) }
end

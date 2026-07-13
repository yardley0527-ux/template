# frozen_string_literal: true

# 每日 AI 晨報：DailyBriefingService 生成後落地一份，
# 首頁只讀最新一筆——不即時呼叫 API（可回溯、成本可控、大家看到同一份）。
class DailyBriefing < ApplicationRecord
  STATUSES = %w[pending success failed].freeze

  validates :briefing_date, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  def self.latest
    order(briefing_date: :desc).first
  end
end

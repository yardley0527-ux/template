# frozen_string_literal: true

# 每週營運檢討報告：WeeklyBriefingService 生成後落地一份（週一為 week_start），
# 首頁與 /weekly_briefings 只讀已落地的資料——不即時呼叫 API，可回溯、成本可控。
# 跟 DailyBriefing 是同一種設計（見 app/services/daily_briefing_service.rb）。
class WeeklyBriefing < ApplicationRecord
  STATUSES = %w[pending success failed].freeze

  has_many :todos, class_name: "WeeklyBriefingTodo", dependent: :destroy, inverse_of: :weekly_briefing

  validates :week_start, presence: true, uniqueness: true
  validates :week_end, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :history, -> { order(week_start: :desc) }

  def self.latest
    order(week_start: :desc).first
  end

  def self.for_week(week_start)
    find_or_initialize_by(week_start: week_start)
  end

  def one_liner
    ai_report["one_liner"]
  end

  def key_numbers
    Array(ai_report["key_numbers"])
  end

  def wins
    Array(ai_report["wins"])
  end

  def issues
    Array(ai_report["issues"])
  end

  def risks
    Array(ai_report["risks"])
  end

  def priorities
    Array(ai_report["priorities"])
  end
end

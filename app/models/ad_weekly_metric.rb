# frozen_string_literal: true

# 廣告週報的 Meta 數字（見 CreateAdWeeklyMetrics）。
class AdWeeklyMetric < ApplicationRecord
  validates :week_end, presence: true, uniqueness: true

  def self.for_week(week_end) = find_by(week_end: week_end)
end

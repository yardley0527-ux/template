# frozen_string_literal: true

# 每日一筆，counts 存當天各會員等級人數快照（{"黑卡"=>82, "金卡"=>211, ...}），
# 供 /customers/stats 回推卡別成長率。同一天重複快照會覆蓋（find_or_initialize_by）。
class MembershipLevelSnapshot < ApplicationRecord
  validates :snapshot_date, presence: true, uniqueness: true
  validates :total, presence: true

  scope :on_or_before, ->(date) { where(snapshot_date: ..date).order(snapshot_date: :desc) }

  def self.closest_to(date)
    on_or_before(date).first
  end

  def count_for(level)
    counts[level].to_i
  end
end

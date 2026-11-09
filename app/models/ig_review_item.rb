# IG 歷史私訊整理後的待審項目。內容來自人工閱讀批次，都是歷史紀錄，未經專業審閱。
class IgReviewItem < ApplicationRecord
  KINDS = {
    "risk" => "高風險回覆",
    "adverse" => "客人不適回報",
    "conflict" => "說法矛盾",
    "followup" => "待追蹤",
    "method" => "溝通做法",
    "usage" => "歷史吃法"
  }.freeze
  # 參考用的類型沒有處理狀態。
  ACTIONABLE = %w[risk adverse conflict followup].freeze
  STATUSES = { "open" => "待處理", "contacted" => "已聯絡", "reviewed" => "已審閱", "closed" => "不需處理" }.freeze
  SEVERITY_ORDER = %w[緊急 最高 高 中].freeze

  validates :source_key, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS.keys }
  validates :status, inclusion: { in: STATUSES.keys }

  def actionable? = ACTIONABLE.include?(kind)
  def severity_rank = SEVERITY_ORDER.index(severity) || SEVERITY_ORDER.size
end

# IG 歷史私訊的整理結果。私訊都已由 Chloe 回覆過，這裡只做整理與查詢，不是待辦清單。
# 內容來自人工閱讀批次，都是歷史紀錄，未經專業審閱。
class IgReviewItem < ApplicationRecord
  KINDS = {
    "risk" => "需修正的說法",
    "adverse" => "客人不適紀錄",
    "conflict" => "說法不一致",
    "followup" => "其他紀錄",
    "method" => "溝通做法",
    "usage" => "歷史吃法"
  }.freeze
  # 舊的處理狀態欄位保留資料，但頁面不再使用。
  STATUSES = { "open" => "待處理", "contacted" => "已聯絡", "reviewed" => "已審閱", "closed" => "不需處理" }.freeze
  SEVERITY_ORDER = %w[最高 高 中].freeze

  validates :source_key, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS.keys }
  validates :status, inclusion: { in: STATUSES.keys }

  def severity_rank = SEVERITY_ORDER.index(severity) || SEVERITY_ORDER.size
end

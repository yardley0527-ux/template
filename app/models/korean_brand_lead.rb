class KoreanBrandLead < ApplicationRecord
  STATUSES = %w[待聯絡 已聯絡・待回覆 已回覆 洽談中 已合作 評估後放棄 已婉拒].freeze

  STATUS_BADGE_CLASSES = {
    "待聯絡"       => "badge-secondary",
    "已聯絡・待回覆" => "badge-warning",
    "已回覆"       => "badge-info",
    "洽談中"       => "badge-primary",
    "已合作"       => "badge-success",
    "評估後放棄"    => "badge-dark",
    "已婉拒"       => "badge-danger",
  }.freeze

  validates :product_name, presence: true
  validates :status, inclusion: { in: STATUSES }

  before_validation { self.status = STATUSES.first if status.blank? }

  scope :ordered, -> { order(Arel.sql("CASE WHEN status = '待聯絡' THEN 1 ELSE 0 END, created_at DESC")) }
end

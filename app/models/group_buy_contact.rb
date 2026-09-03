class GroupBuyContact < ApplicationRecord
  STATUSES = %w[待回覆 已回覆 洽談中 已成團 婉拒 未回應].freeze
  CHANNELS = %w[Email IG留言 IG私訊 其他].freeze

  validates :brand_name, presence: true
  validates :status, inclusion: { in: STATUSES }

  before_validation { self.status = "待回覆" if status.blank? }

  default_scope { order(contacted_on: :desc, id: :desc) }
end

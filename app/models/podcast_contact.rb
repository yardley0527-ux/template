class PodcastContact < ApplicationRecord
  STATUSES = %w[待接洽 已接洽 未回覆 已回覆 合作中 已合作 婉拒].freeze

  validates :ig_username, presence: true, uniqueness: true

  before_validation { self.status = "待接洽" if status.blank? }

  scope :ordered, -> { order(:ig_username) }
  scope :pr_gift_shipped, -> { where.not(pr_gift_shipped_at: nil) }

  def profile_link
    profile_url.presence || "https://www.instagram.com/#{ig_username}"
  end
end

class ReloveKoc < ApplicationRecord
  STATUSES = %w[待接洽 已接洽 已回覆 合作中 已合作 婉拒].freeze

  validates :ig_username, presence: true, uniqueness: true

  before_validation { self.status = "待接洽" if status.blank? }

  scope :ordered_by_engagement, -> { order(Arel.sql("COALESCE(max_video_views, 0) DESC, COALESCE(max_likes, 0) DESC")) }

  def profile_link
    profile_url.presence || "https://www.instagram.com/#{ig_username}"
  end
end

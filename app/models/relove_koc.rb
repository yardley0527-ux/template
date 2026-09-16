class ReloveKoc < ApplicationRecord
  STATUSES = %w[待接洽 已接洽 未回覆 已回覆 合作中 已合作 婉拒].freeze
  VIDEO_SHOOT_STATUSES = %w[未拍攝 已拍攝].freeze

  validates :ig_username, presence: true, uniqueness: true

  before_validation { self.status = "待接洽" if status.blank? }
  before_validation { self.video_shoot_status = "未拍攝" if video_shoot_status.blank? }

  scope :ordered_by_engagement, -> { order(Arel.sql("COALESCE(max_video_views, 0) DESC, COALESCE(max_likes, 0) DESC")) }

  def profile_link
    profile_url.presence || "https://www.instagram.com/#{ig_username}"
  end
end

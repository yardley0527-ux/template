class IgProfile < ApplicationRecord
  has_many :ig_snapshots, dependent: :destroy
  has_many :ig_posts, dependent: :destroy

  def avg_likes
    return 0 if ig_posts.none?
    ig_posts.average(:likes).to_f.round(1)
  end

  def avg_comments
    return 0 if ig_posts.none?
    ig_posts.average(:comments).to_f.round(1)
  end

  def engagement_rate
    return 0.0 if follower_count.zero?
    ((avg_likes + avg_comments) / follower_count.to_f * 100).round(2)
  end

  def latest_post_date
    ig_posts.maximum(:posted_at)
  end

  def ig_url
    "https://www.instagram.com/#{username}/"
  end
end

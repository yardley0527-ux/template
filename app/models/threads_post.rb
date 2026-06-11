class ThreadsPost < ApplicationRecord
  scope :today,  -> { where(fetched_on: Date.today) }
  scope :recent, -> { where(fetched_on: 7.days.ago.to_date..) }

  def engagement_score
    like_count + reply_count * 2 + repost_count
  end
end

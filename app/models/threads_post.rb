class ThreadsPost < ApplicationRecord
  scope :today,  -> { where(fetched_on: Date.today) }
  scope :recent, -> { where(fetched_on: 7.days.ago.to_date..) }

  def engagement_score
    reply_count * 5 + like_count
  end
end

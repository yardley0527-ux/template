class ThreadsFetchLog < ApplicationRecord
  scope :recent, -> { where("fetched_at > ?", 6.hours.ago) }

  def self.recently_fetched?(category)
    where(category: category, status: "success").recent.exists?
  end
end

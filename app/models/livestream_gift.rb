class LivestreamGift < ApplicationRecord
  belongs_to :livestream

  validates :description, presence: true
end

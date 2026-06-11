class LivestreamImage < ApplicationRecord
  belongs_to :livestream

  validates :cloudinary_public_id, presence: true
  validates :url, presence: true
end

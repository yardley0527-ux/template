class LineBroadcastHighlight < ApplicationRecord
  validates :cloudinary_public_id, presence: true
  validates :image_url, presence: true

  default_scope { order(position: :asc, created_at: :asc) }
end

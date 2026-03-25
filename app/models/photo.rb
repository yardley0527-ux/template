class Photo < ApplicationRecord
  belongs_to :album

  validates :cloudinary_public_id, presence: true
  validates :url, presence: true

  default_scope { order(position: :asc, created_at: :asc) }
end
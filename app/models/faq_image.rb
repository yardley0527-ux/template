class FaqImage < ApplicationRecord
  belongs_to :faq

  validates :cloudinary_public_id, :url, presence: true
end

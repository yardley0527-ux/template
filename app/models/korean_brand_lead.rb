class KoreanBrandLead < ApplicationRecord
  validates :product_name, presence: true

  scope :ordered, -> { order(contacted: :desc, created_at: :desc) }
end

class Livestream < ApplicationRecord
  has_many :livestream_images, -> { order(position: :asc) }, dependent: :destroy
  has_many :livestream_products, -> { order(position: :asc) }, dependent: :destroy
  has_many :livestream_gifts, -> { order(position: :asc) }, dependent: :destroy

  validates :date, presence: true, uniqueness: true

  default_scope { order(date: :desc) }
end

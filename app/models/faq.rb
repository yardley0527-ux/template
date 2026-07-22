class Faq < ApplicationRecord
  belongs_to :faq_category
  has_many :faq_images, -> { order(:position) }, dependent: :destroy

  validates :question, presence: true
end

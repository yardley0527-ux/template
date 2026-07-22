class FaqCategory < ApplicationRecord
  has_many :faqs, -> { order(:position) }, dependent: :destroy

  validates :name, presence: true
end

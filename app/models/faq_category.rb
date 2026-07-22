class FaqCategory < ApplicationRecord
  has_many :faqs, -> { order(:position) }, dependent: :destroy

  validates :name, presence: true

  def self.hue_for_index(index)
    (index * 30 + 12) % 360
  end

  def hue
    index = FaqCategory.order(:position).pluck(:id).index(id) || 0
    self.class.hue_for_index(index)
  end
end

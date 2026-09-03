class KolQuoteItem < ApplicationRecord
  belongs_to :kol_candidate

  validates :item_name, presence: true
  validates :amount, numericality: true
end

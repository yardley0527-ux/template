class OrderGiftRecord < ApplicationRecord
  validates :order_number, presence: true, uniqueness: true
end

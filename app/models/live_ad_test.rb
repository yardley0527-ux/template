class LiveAdTest < ApplicationRecord
  validates :date, presence: true

  default_scope { order(date: :desc) }
end

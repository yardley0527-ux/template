class Album < ApplicationRecord
  belongs_to :shopline_customer
  has_many :photos, dependent: :destroy

  validates :name, presence: true
  
  default_scope { order(created_at: :desc) }
end
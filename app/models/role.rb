class Role < ApplicationRecord
  ADMIN_KEY = "admin".freeze

  has_many :users, dependent: :nullify
  has_many :page_permissions, dependent: :destroy

  validates :key, presence: true, uniqueness: true
  validates :name, presence: true

  def admin?
    key == ADMIN_KEY
  end
end

class PagePermission < ApplicationRecord
  belongs_to :role

  validates :controller_name, presence: true, uniqueness: { scope: :role_id }
end

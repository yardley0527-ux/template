# frozen_string_literal: true

class CrmProduct < ApplicationRecord
  KEY_FORMAT = /\A[a-z][a-z0-9_]*\z/
  STATUSES   = %w[candidate confirmed merged ignored].freeze

  has_many :product_name_mappings, foreign_key: :crm_product_id, inverse_of: :crm_product
  has_many :suggested_for_mappings, class_name: "ProductNameMapping",
           foreign_key: :suggested_crm_product_id, inverse_of: :suggested_crm_product
  belongs_to :reviewed_by, class_name: "User", foreign_key: :reviewed_by_user_id, optional: true

  validates :key, presence: true, uniqueness: true, format: { with: KEY_FORMAT }
  validates :label, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :confirmed, -> { where(status: "confirmed") }
end

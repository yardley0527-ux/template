# frozen_string_literal: true

class ProductNameMapping < ApplicationRecord
  SOURCES         = %w[shopline_order livestream_product analysis_note].freeze
  MAPPING_STATUSES = %w[pending confirmed_alias new_key_needed ignored].freeze
  CONFIDENCES     = %w[High Medium Low].freeze

  belongs_to :crm_product, optional: true
  belongs_to :suggested_crm_product, class_name: "CrmProduct", optional: true
  belongs_to :reviewed_by, class_name: "User", foreign_key: :reviewed_by_user_id, optional: true

  validates :raw_name, presence: true
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :mapping_status, presence: true, inclusion: { in: MAPPING_STATUSES }
  validates :suggested_confidence, inclusion: { in: CONFIDENCES }, allow_nil: true
  validates :raw_name, uniqueness: { scope: :source }

  scope :pending, -> { where(mapping_status: "pending") }
end

# frozen_string_literal: true

class CrmProductAlias < ApplicationRecord
  STATUSES = %w[active inactive].freeze
  SOURCES  = %w[seed manual generated].freeze

  belongs_to :crm_product

  validates :alias_name,       presence: true
  validates :normalized_alias, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :alias_name, uniqueness: { scope: :crm_product_id,
                                       message: "already registered for this product" }

  before_validation :set_normalized_alias

  scope :active,   -> { where(status: "active") }
  scope :inactive, -> { where(status: "inactive") }

  private

  def set_normalized_alias
    self.normalized_alias = alias_name.to_s.unicode_normalize(:nfc).strip if alias_name.present?
  end
end

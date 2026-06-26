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

  scope :confirmed,     -> { where(status: "confirmed") }
  scope :for_analysis,  -> { confirmed.where(include_in_analysis: true) }

  # ── Repository helpers (Single Source of Truth for product metadata) ──

  # Labels in id order — drop-in replacement for hard-coded SERIES_OPTIONS arrays.
  def self.series_labels
    for_analysis.order(:id).pluck(:label)
  end

  # Keys in id order.
  def self.all_keys
    for_analysis.order(:id).pluck(:key)
  end

  # Find by key or raise (avoids scattered find_by + nil checks).
  def self.fetch(key)
    find_by!(key: key.to_s)
  end

  # Build the legacy-compatible LIKE sql_pattern for a product_key.
  # Returns the stored sql_pattern if present; falls back to a label-based LIKE.
  def self.sql_for(key)
    crm = find_by(key: key.to_s)
    crm&.sql_pattern.presence || crm && "product_name LIKE '%#{crm.label}%'"
  end

  # Build a Regexp from the stored regex_pattern, or nil.
  def compiled_regex
    return nil unless regex_pattern.present?
    Regexp.new(regex_pattern)
  rescue RegexpError
    nil
  end
end

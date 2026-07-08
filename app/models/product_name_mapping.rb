# frozen_string_literal: true

class ProductNameMapping < ApplicationRecord
  SOURCES         = %w[shopline_order livestream_product analysis_note].freeze
  MAPPING_STATUSES = %w[pending confirmed_alias new_key_needed ignored].freeze
  CONFIDENCES     = %w[High Medium Low].freeze

  belongs_to :crm_product, optional: true
  belongs_to :suggested_crm_product, class_name: "CrmProduct", optional: true
  belongs_to :reviewed_by, class_name: "User", foreign_key: :reviewed_by_user_id, optional: true

  has_many :components, class_name: "ProductMappingComponent",
           foreign_key: :product_name_mapping_id, dependent: :destroy
  has_many :component_products, through: :components, source: :crm_product

  has_many :mapping_logs, class_name: "ProductNameMappingLog", dependent: :destroy

  validates :raw_name, presence: true
  validates :source, presence: true, inclusion: { in: SOURCES }
  validates :mapping_status, presence: true, inclusion: { in: MAPPING_STATUSES }
  validates :suggested_confidence, inclusion: { in: CONFIDENCES }, allow_nil: true
  validates :raw_name, uniqueness: { scope: :source }

  scope :pending,   -> { where(mapping_status: "pending") }
  scope :confirmed, -> { where(mapping_status: "confirmed_alias") }

  # Mappings decomposed into more than one product. NOT the same as "has any
  # component" — every confirmed mapping is expected to have >= 1 component
  # (Epic E3), including single-product SKUs, so `joins(:components)` alone
  # would match almost everything and no longer means "bundle".
  scope :bundles, -> {
    joins(:components)
      .group("product_name_mappings.id")
      .having("COUNT(product_mapping_components.id) > 1")
  }

  # True when this SKU's raw_name represents more than one distinct product
  # (e.g. "薑黃1全能1"). A mapping with exactly one component (including every
  # single-product mapping under Epic E3) is NOT a bundle — component
  # existence and "is a bundle" are different questions, see
  # ProductMappingComponent's class comment.
  def bundle?
    components.count > 1
  end

  # Returns the next mapping_version for a new log entry on this mapping.
  # mapping_version is scoped per record: first event = 1, second = 2, etc.
  # Called by ProductNameMappingHistoryService.record! before each insert.
  def next_mapping_version
    mapping_logs.maximum(:mapping_version).to_i + 1
  end

  # ── Resolver helpers (used by ProductNameResolver service) ────────────

  # Returns the CrmProduct for a single raw name, or nil if unmapped.
  def self.resolve(raw_name)
    return nil if raw_name.blank?
    includes(:crm_product)
      .find_by(raw_name: raw_name.to_s.strip, mapping_status: "confirmed_alias")
      &.crm_product
  end

  # Returns { raw_name => CrmProduct } for a collection of names.
  # Names with no confirmed mapping are absent from the result hash.
  def self.resolve_batch(raw_names)
    return {} if raw_names.blank?
    normalized = raw_names.map { |n| n.to_s.strip }.uniq.reject(&:blank?)
    includes(:crm_product)
      .where(raw_name: normalized, mapping_status: "confirmed_alias")
      .each_with_object({}) { |m, h| h[m.raw_name] = m.crm_product }
  end
end

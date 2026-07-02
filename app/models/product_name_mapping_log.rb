# frozen_string_literal: true

# One row per status transition on a ProductNameMapping.
#
# mapping_version — scoped per mapping, increments on every recorded transition:
#   first confirm → 1, undo → 2, re-confirm → 3, …
#
# action      — what workflow step fired (confirm / bulk_confirm / ignore / etc.)
# change_source — which system component called ProductNameMappingHistoryService
#
# performed_at is intentionally absent; created_at IS the event timestamp.
# See ProductNameMappingHistoryService for the canonical write path.
class ProductNameMappingLog < ApplicationRecord
  ACTIONS = %w[confirm ignore undo bulk_confirm bulk_ignore].freeze
  CHANGE_SOURCES = %w[bulk_confirm bulk_ignore manual_ui migration bundle_parser api system].freeze

  belongs_to :product_name_mapping
  belongs_to :old_crm_product,  class_name: "CrmProduct", optional: true,
             foreign_key: :old_crm_product_id
  belongs_to :new_crm_product,  class_name: "CrmProduct", optional: true,
             foreign_key: :new_crm_product_id
  belongs_to :performed_by, class_name: "User",
             foreign_key: :performed_by_user_id, optional: true

  # action enum — no prefix; primary dimension for querying history.
  # Generates: confirm?, ignore?, undo?, bulk_confirm?, bulk_ignore?
  #            confirm!, ignore!, undo!, bulk_confirm!, bulk_ignore!
  #            Scopes: ProductNameMappingLog.confirm, .bulk_confirm, etc.
  enum :action, {
    confirm:      "confirm",
    ignore:       "ignore",
    undo:         "undo",
    bulk_confirm: "bulk_confirm",
    bulk_ignore:  "bulk_ignore",
  }

  # change_source enum — prefix :source to avoid collisions with action enum.
  # Generates: source_bulk_confirm?, source_manual_ui?, source_system?, etc.
  enum :change_source, {
    bulk_confirm:  "bulk_confirm",
    bulk_ignore:   "bulk_ignore",
    manual_ui:     "manual_ui",
    migration:     "migration",
    bundle_parser: "bundle_parser",
    api:           "api",
    system:        "system",
  }, prefix: :source

  # Rails 7.1 enum raises ArgumentError on invalid values before validation runs,
  # so inclusion: checks on :action and :change_source are redundant.
  validates :action,          presence: true
  validates :change_source,   presence: true
  validates :from_status,     presence: true
  validates :to_status,       presence: true
  validates :mapping_version, presence: true,
                              numericality: { only_integer: true, greater_than: 0 }
end

# frozen_string_literal: true

# Read-only reconciliation between the DANDY inventory snapshot
# (DandyInventorySnapshot, synced hourly from the same spreadsheet shown on
# /product_inventory) and the 13 crm_products seeded for Notification Board
# Phase 0A.
#
# Deliberately separate from CrmProductAlias / ProductRegistryBootstrapService
# ALIASES_BY_KEY: those drive regex_pattern generation, which feeds bottle
# parsing, quantity parsing, and product_name_mapping candidate generation for
# ShoplineOrder/livestream product names — an entirely different matching
# problem with real production blast radius. Widening that alias set for a
# handful of DANDY-spreadsheet-only spellings ("全能B群" vs "全能") would
# change what counts as a match there too. This service keeps DANDY-name
# resolution self-contained: exact match only (existing active aliases, plus
# a short explicit override list below for known DANDY-only spellings) —
# never a substring/fuzzy guess, so an unrecognized name is reported as
# unmapped rather than silently attached to the wrong product.
#
# Writes nothing. crm_products.availability_status stays under explicit human
# control (see CrmProduct's comment above #available_for_reminders? — status
# transitions are deliberately not automatic). This service only tells you
# where DANDY's data and the current availability_status might disagree, or
# where a product has no DANDY row at all — deciding what stock number should
# map to which availability_status is a business call for a human, not this
# service.
class DandyInventoryReconciliationService
  # Literal DANDY spreadsheet spellings that don't match any active
  # crm_product_aliases.normalized_alias verbatim, confirmed by manual
  # inventory_note entries (owner@shengting.com, 2026-07-22) as referring to
  # that product. Exact strings only — no regex, no partial match.
  DANDY_NAME_OVERRIDES = {
    "全能B群"     => "omnipotent",
    "外泌體面膜"   => "mask",
    "維生素D+鈣"  => "vitamin_dk_calcium"
  }.freeze

  Result = Struct.new(:snapshot_date, :mapped, :unmapped_dandy_rows, :products_without_dandy_row,
                       :duplicate_targets, keyword_init: true)

  def self.call
    new.call
  end

  def call
    snapshot = DandyInventorySnapshot.latest
    return Result.new(snapshot_date: nil, mapped: [], unmapped_dandy_rows: [],
                       products_without_dandy_row: CrmProduct.confirmed.pluck(:key), duplicate_targets: []) unless snapshot

    alias_lookup = build_alias_lookup
    rows = snapshot.supplements["rows"] || []

    mapped = []
    unmapped = []
    seen_products = {}

    rows.each do |row|
      name = row["name"].to_s.strip
      crm_key = alias_lookup[name] || DANDY_NAME_OVERRIDES[name]

      if crm_key.nil?
        unmapped << { dandy_name: name, realtime: row["values"]&.last }
        next
      end

      (seen_products[crm_key] ||= []) << name
      mapped << { dandy_name: name, crm_key: crm_key, realtime: row["values"]&.last }
    end

    duplicates = seen_products.select { |_, names| names.size > 1 }
                               .map { |crm_key, names| { crm_key: crm_key, dandy_names: names } }

    mapped_keys = mapped.map { |m| m[:crm_key] }
    without_row = CrmProduct.confirmed.where.not(key: mapped_keys).pluck(:key)

    Result.new(snapshot_date: snapshot.snapshot_date, mapped: mapped, unmapped_dandy_rows: unmapped,
               products_without_dandy_row: without_row, duplicate_targets: duplicates)
  end

  private

  # crm_product_id => key, keyed by every active alias's normalized form.
  def build_alias_lookup
    key_by_product_id = CrmProduct.confirmed.pluck(:id, :key).to_h
    CrmProductAlias.active.pluck(:normalized_alias, :crm_product_id).each_with_object({}) do |(name, product_id), h|
      h[name] = key_by_product_id[product_id]
    end
  end
end

# frozen_string_literal: true

# Epic E3-2: dry-run report for ProductQuantityParserService.
#
# Read-only — never writes ProductMappingComponent. Scans every confirmed
# mapping, runs the new parser, and:
#
#   1. Flags mappings the parser found zero components for (raw_name matched
#      no CrmProduct regex — worth human review before E3-3 writes anything).
#   2. Diffs the parser's result against any ALREADY-existing components
#      (the 90 mappings Epic C's bundle_components:write wrote before E3
#      existed) — new parsing logic (regex+span, gift-aware) vs. old
#      (keyword ALIAS_MAP, no gift concept) can disagree. Rows whose raw_name
#      contains 送/贈 are flagged separately since that's exactly where the
#      old parser is known to misparse gifts as paid components (see E3-1
#      commit message for a concrete example: "代謝錠12送全能2").
#
# Usage (Rails console or rake task):
#   result = ProductQuantityParserDryRunReportService.call
#   result[:total_confirmed]
#   result[:diffs]
class ProductQuantityParserDryRunReportService
  PROMOTION_MARKER_PATTERN = /[送贈]/.freeze

  def self.call
    new.call
  end

  def call
    confirmed = ProductNameMapping
      .confirmed
      .includes(components: :crm_product)
      .order(:raw_name)
      .to_a

    # Load products once for the whole batch instead of once per raw_name.
    products = CrmProduct.where.not(regex_pattern: [nil, ""]).to_a

    parsed_by_mapping_id = confirmed.each_with_object({}) do |mapping, h|
      h[mapping.id] = ProductQuantityParserService.call(mapping.raw_name, products: products)
    end

    unparsed = confirmed.select { |m| parsed_by_mapping_id[m.id].components.empty? }
    already_componented = confirmed.select { |m| m.components.any? }
    diffs = already_componented.filter_map { |m| build_diff(m, parsed_by_mapping_id[m.id]) }

    # The set E3-3 would write: confirmed, no components yet, parseable.
    # NOT derivable from the other counts by arithmetic — unparsed and
    # already_componented overlap (rows Epic C componented that the new
    # parser can't match at all).
    would_write = confirmed.select do |m|
      m.components.empty? && parsed_by_mapping_id[m.id].components.any?
    end

    gift_diffs = diffs.select { |d| d[:contains_promotion_marker] }

    {
      total_confirmed:           confirmed.size,
      total_unparsed:            unparsed.size,
      unparsed_raw_names:        unparsed.map(&:raw_name),
      already_componented:       already_componented.size,
      would_write_new_count:     would_write.size,
      would_write_new_raw_names: would_write.map(&:raw_name),
      diffs:                     diffs,
      diffs_with_promotion:      gift_diffs,
      sample_parsed:             sample_parsed(confirmed, parsed_by_mapping_id),

      # Flat summary aliases — same numbers as above, named for quick
      # production spot-checks via `.slice(...)` in rails runner. Counts
      # only, no arrays.
      parsed_count:                 confirmed.size - unparsed.size,
      unparsed_count:               unparsed.size,
      already_has_components_count: already_componented.size,
      would_write_count:            would_write.size,
      diff_count:                   diffs.size,
      gift_diff_count:              gift_diffs.size,
    }
  end

  private

  # A handful of successfully-parsed rows for spot-checking, preferring ones
  # with more than one component (the more interesting bundle/gift cases).
  def sample_parsed(confirmed, parsed_by_mapping_id)
    parsed = confirmed.filter_map do |m|
      result = parsed_by_mapping_id[m.id]
      next if result.components.empty?

      { raw_name: m.raw_name, components: result.components }
    end

    parsed.sort_by { |r| -r[:components].size }.first(30)
  end

  def build_diff(mapping, parsed_result)
    new_state = state_from_parsed(parsed_result)
    old_state = state_from_existing(mapping)

    return nil if new_state == old_state

    {
      mapping_id:                mapping.id,
      raw_name:                  mapping.raw_name,
      old_state:                 old_state,
      new_state:                 new_state,
      contains_promotion_marker: mapping.raw_name.match?(PROMOTION_MARKER_PATTERN),
    }
  end

  def state_from_parsed(parsed_result)
    parsed_result.components.each_with_object({}) do |c, h|
      h[c[:crm_product_key]] = { paid: c[:paid_quantity], gift: c[:gift_quantity] }
    end
  end

  def state_from_existing(mapping)
    mapping.components.each_with_object({}) do |c, h|
      h[c.crm_product.key] = { paid: c.paid_quantity, gift: c.gift_quantity }
    end
  end
end

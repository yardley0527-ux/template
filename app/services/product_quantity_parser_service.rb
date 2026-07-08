# frozen_string_literal: true

# Epic E3-2: parses a raw_name into per-product paid/gift quantity.
#
# Read-only — never touches the database, never writes ProductMappingComponent.
# That's a later step (E3-3/E3-4); this class only answers "if I were to
# write components for this raw_name, what would they look like."
#
# Reuses ProductNameMappingReviewReportService.find_matches_with_spans as the
# single source of truth for "which CrmProducts does this raw_name match, and
# where" — same regex/span logic Bulk Confirm's classification is built on.
# Do not reimplement product matching here.
#
# Algorithm, given the matches + their spans/captured quantities:
#
#   1. Each matched product's captured digit (e.g. "全能10" → 10) is that
#      product's own quantity.
#   2. If a "送" or "贈" character immediately precedes a product's match
#      (optionally with whitespace between), that product's ENTIRE quantity
#      is a gift, not a purchase — this is the "送面膜1" case: 面膜 is a
#      separate product, wholly given away.
#   3. Any remaining "送N" / "贈N" that is NOT immediately followed by a
#      product name (i.e. a bare number right after 送/贈, like "送2") adds N
#      to the gift_quantity of the nearest PRECEDING matched product — this
#      is the "全能10送2" case: the same product gets 2 bonus units.
#
# Usage:
#   result = ProductQuantityParserService.call("全能10送2")
#   result.components
#   # => [{ crm_product_key: "omnipotent", crm_product_label: "全能",
#   #        paid_quantity: 10, gift_quantity: 2, total_quantity: 12 }]
#
# Known limitation (inherited from find_matches_with_spans, not new here):
# a product mentioned twice in one raw_name is only counted once (first
# match wins) — e.g. "代謝錠1薑黃1送清纖粉代謝錠1薑黃1送薑黃" collapses to a
# single 代謝錠/薑黃 entry each, not summed across both mentions.
class ProductQuantityParserService
  Result = Struct.new(:components, keyword_init: true)

  # Bare gift addition: 送 or 贈 immediately followed by a number, with no
  # product name in between (e.g. "送2", "贈1"). If a product name comes
  # right after 送/贈 instead, that's handled by gift_marker_precedes? below,
  # not this pattern — "送面膜1" does NOT match here because 面 isn't a digit.
  BARE_GIFT_PATTERN = /[送贈](\d+)/.freeze

  # Character(s) that, immediately before a product match, mark that whole
  # match as a gift rather than a purchase.
  GIFT_MARKER_PREFIX_PATTERN = /[送贈]\s*\z/.freeze

  def self.call(raw_name)
    new.parse(raw_name.to_s.strip)
  end

  def parse(raw_name)
    return Result.new(components: []) if raw_name.blank?

    products_with_regex = CrmProduct.where.not(regex_pattern: [nil, ""]).to_a
    matches = ProductNameMappingReviewReportService
      .find_matches_with_spans(raw_name, products_with_regex)
      .sort_by { |m| m[:span].begin }

    totals = {}
    matches.each do |m|
      entry = (totals[m[:product].id] ||= { product: m[:product], paid: 0, gift: 0 })

      if gift_marker_precedes?(raw_name, m[:span])
        entry[:gift] += m[:quantity]
      else
        entry[:paid] += m[:quantity]
      end
    end

    attach_bare_gift_additions(raw_name, matches, totals)

    components = totals.values.map do |entry|
      {
        crm_product_key:   entry[:product].key,
        crm_product_label: entry[:product].label,
        paid_quantity:     entry[:paid],
        gift_quantity:     entry[:gift],
        total_quantity:    entry[:paid] + entry[:gift],
      }
    end

    Result.new(components: components)
  end

  private

  def gift_marker_precedes?(raw_name, span)
    raw_name[0...span.begin].match?(GIFT_MARKER_PREFIX_PATTERN)
  end

  # Bare "送N"/"贈N" occurrences (no product name attached) add N gift units
  # to whichever matched product's span ends closest before that position.
  def attach_bare_gift_additions(raw_name, matches, totals)
    raw_name.to_enum(:scan, BARE_GIFT_PATTERN).each do
      md       = Regexp.last_match
      gift_qty = md[1].to_i
      position = md.begin(0)

      preceding = matches.select { |m| m[:span].end <= position }.max_by { |m| m[:span].end }
      next unless preceding

      totals[preceding[:product].id][:gift] += gift_qty
    end
  end
end

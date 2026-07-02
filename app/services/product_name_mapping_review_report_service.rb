# frozen_string_literal: true

# Bulk Confirm Readiness Report v3 — read-only, zero DB writes.
#
# Classifies ALL pending ProductNameMappings into FIVE action buckets:
#
#   A. single_product_regex_confirmable
#        Exactly one CrmProduct regex matched the raw_name AND suggested_confidence
#        is High.  Safe to bulk-confirm as the first batch.
#
#   B. bundle_candidate
#        Two or more DISTINCT CrmProduct regexes matched, AND their match spans
#        are non-overlapping (each product's keyword+digit appears at a separate
#        position in the string).  Clearly a multi-product SKU.
#        Do NOT bulk-confirm — hand off to Bundle Components Parser.
#        Each row includes matched_products[] and matched_count for the parser.
#
#   C. ambiguous_regex_match
#        Two or more distinct CrmProduct regexes matched, BUT their match spans
#        overlap.  Likely a too-broad regex or alias overlap, not a true bundle.
#        Do NOT bulk-confirm or send to Bundle Parser.
#        Inspect regex_pattern strings for the matched products.
#        Each row includes matched_products[], matched_count, and reason: "regex_overlap".
#
#   D. keyword_spot_check
#        Zero regex matches AND suggested_confidence == High.
#        Suggestion came from core-keyword, label-segment, or trigram logic.
#        Spot-check a sample before bulk action.
#
#   E. low_or_no_suggestion
#        Zero regex matches AND confidence is Medium / Low / nil.
#        Manual review last.
#
# Bundle vs ambiguous detection (non-overlapping span check):
#   For each CrmProduct whose regex matches, record the character-position span
#   [begin, end) of the first match.  Sort spans by start position and check that
#   each span ends (exclusive) at or before the next span begins.  If all spans
#   are non-overlapping → true bundle.  If any two spans overlap → regex/alias
#   overlap → ambiguous.
#
#   Example:
#     "薑黃1全能1" (6 chars)
#       /薑黃(\d+)/ → span 0..3  ─┐ non-overlapping → bundle_candidate
#       /全能(\d+)/ → span 3..6  ─┘
#
#     Hypothetical "膠原1" if two patterns matched starting at position 0:
#       pattern_A → span 0..3  ─┐ overlapping (same start) → ambiguous_regex_match
#       pattern_B → span 0..3  ─┘
#
# Usage (Rails console):
#   report = ProductNameMappingReviewReportService.call
#   report[:summary]
#   report[:bulk_confirm_readiness]
#   report[:single_product_regex_confirmable].take(20)
#   report[:bundle_candidate].take(20)
#   report[:ambiguous_regex_match].take(20)
#   report[:keyword_spot_check].take(20)
#   report[:low_or_no_suggestion].take(20)
class ProductNameMappingReviewReportService
  def self.call
    new.call
  end

  def call
    # Load all CrmProducts that have a regex — used for bundle/overlap detection.
    # Fetched once; each product's regex is tested against every pending raw_name.
    products_with_regex = CrmProduct.where.not(regex_pattern: [nil, ""]).to_a

    # Load all pending mappings sorted by occurrence_count DESC.
    # Sort order is preserved as rows are appended to each bucket.
    pending = ProductNameMapping
      .pending
      .includes(:suggested_crm_product)
      .order(occurrence_count: :desc)
      .to_a

    # ── Classify into five buckets ─────────────────────────────────────────
    buckets = {
      single_product_regex_confirmable: [],
      bundle_candidate:                 [],
      ambiguous_regex_match:            [],
      keyword_spot_check:               [],
      low_or_no_suggestion:             [],
    }

    pending.each do |mapping|
      # Find which CrmProduct regexes match, with their character-span.
      # Deduplicated by product id — each product counted at most once.
      matched = find_matches_with_spans(mapping.raw_name, products_with_regex)
      bucket  = classify(mapping, matched)
      buckets[bucket] << build_row(mapping, matched, bucket)
    end

    # ── Summary ────────────────────────────────────────────────────────────
    summary = {
      pending_total:     pending.size,
      high_confidence:   pending.count { |m| m.suggested_confidence == "High"   },
      medium_confidence: pending.count { |m| m.suggested_confidence == "Medium" },
      low_confidence:    pending.count { |m| m.suggested_confidence == "Low"    },
      no_suggestion:     pending.count { |m| m.suggested_confidence.nil?        },
    }

    bulk_confirm_readiness = {
      single_product_regex_confirmable: buckets[:single_product_regex_confirmable].size,
      bundle_candidate:                 buckets[:bundle_candidate].size,
      ambiguous_regex_match:            buckets[:ambiguous_regex_match].size,
      keyword_spot_check:               buckets[:keyword_spot_check].size,
      low_or_no_suggestion:             buckets[:low_or_no_suggestion].size,
    }

    {
      summary:                          summary,
      bulk_confirm_readiness:           bulk_confirm_readiness,
      single_product_regex_confirmable: buckets[:single_product_regex_confirmable],
      bundle_candidate:                 buckets[:bundle_candidate],
      ambiguous_regex_match:            buckets[:ambiguous_regex_match],
      keyword_spot_check:               buckets[:keyword_spot_check],
      low_or_no_suggestion:             buckets[:low_or_no_suggestion],
    }
  end

  private

  # ── Step 1: regex match with span capture ──────────────────────────────

  # Returns an array of { product:, span: (begin...end) }, one entry per
  # matching CrmProduct, deduplicated by product id (first match wins).
  # Character positions are used (not byte positions) so span comparison
  # is correct for multi-byte UTF-8 strings.
  def find_matches_with_spans(raw_name, products)
    seen    = {}
    matches = []

    products.each do |product|
      next if seen.key?(product.id)

      begin
        m = Regexp.new(product.regex_pattern).match(raw_name)
        if m
          matches << { product: product, span: (m.begin(0)...m.end(0)) }
          seen[product.id] = true
        end
      rescue RegexpError
        # skip products with a malformed stored regex_pattern
      end
    end

    matches
  end

  # ── Step 2: classify ───────────────────────────────────────────────────

  def classify(mapping, matched)
    unique_count = matched.size  # already deduplicated per product

    if unique_count >= 2
      non_overlapping_spans?(matched) ? :bundle_candidate : :ambiguous_regex_match
    elsif unique_count == 1 && mapping.suggested_confidence == "High"
      :single_product_regex_confirmable
    elsif unique_count == 0 && mapping.suggested_confidence == "High"
      :keyword_spot_check
    else
      :low_or_no_suggestion
    end
  end

  # Returns true when all match spans are sequential (no character overlap).
  # Sorts by span start then checks each consecutive pair.
  def non_overlapping_spans?(matched)
    spans = matched.map { |m| m[:span] }.sort_by(&:begin)
    spans.each_cons(2).all? { |a, b| a.end <= b.begin }
  end

  # ── Step 3: build output row ────────────────────────────────────────────

  def build_row(mapping, matched, bucket)
    suggested      = mapping.suggested_crm_product
    matched_labels = matched.map { |m| m[:product].label }

    row = {
      raw_name:              mapping.raw_name,
      occurrence_count:      mapping.occurrence_count,
      suggested_crm_product: suggested&.label,
      confidence:            mapping.suggested_confidence,
      source:                mapping.source,
      matched_products:      matched_labels,
      matched_count:         matched.size,
    }

    # Surface the overlap reason so reviewers know which regex(es) to tighten.
    row[:reason] = "regex_overlap" if bucket == :ambiguous_regex_match

    row
  end
end

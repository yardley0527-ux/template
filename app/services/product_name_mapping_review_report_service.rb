# frozen_string_literal: true

# Bulk Confirm Readiness Report v4 — read-only, zero DB writes.
#
# Epic E2-1: adds action_type and promotion_detected to every row.
#
# FIVE bucket classification (unchanged from v3):
#
#   A. single_product_regex_confirmable — 1 regex match, High confidence
#   B. bundle_candidate                — 2+ matches, non-overlapping spans
#   C. ambiguous_regex_match           — 2+ matches, overlapping spans
#   D. keyword_spot_check              — 0 matches, High confidence
#   E. low_or_no_suggestion            — 0 matches, Medium / Low / nil
#
# Action type (one per row, derived from bucket):
#
#   bulk_confirm    ← single_product_regex_confirmable
#   bundle_review   ← bundle_candidate
#   keyword_review  ← keyword_spot_check
#   manual_review   ← ambiguous_regex_match, low_or_no_suggestion
#
# Promotion detection (orthogonal — does NOT change bucket or action_type):
#
#   promotion_detected = true  when raw_name matches /送\d+|贈\d+/
#   Examples: "代謝錠2送1", "全能10送2", "穀胱甘肽10送2送面膜1" → true
#             "全能1"                                           → false
#
# Usage (Rails console):
#   report = ProductNameMappingReviewReportService.call
#   report[:summary]
#   report[:action_summary]
#   report[:bulk_confirm_readiness]
#   report[:single_product_regex_confirmable].take(20)
#   report[:bundle_candidate].take(20)
#   report[:ambiguous_regex_match].take(20)
#   report[:keyword_spot_check].take(20)
#   report[:low_or_no_suggestion].take(20)
class ProductNameMappingReviewReportService
  # Promotion keywords that signal a buy-X-get-Y offer embedded in the SKU name.
  # Detection is informational only — does not affect bucket or action_type.
  PROMOTION_PATTERN = /送\d+|贈\d+/.freeze

  # Maps the 5 classification buckets to the 4 workflow action types.
  BUCKET_TO_ACTION_TYPE = {
    single_product_regex_confirmable: :bulk_confirm,
    bundle_candidate:                 :bundle_review,
    ambiguous_regex_match:            :manual_review,
    keyword_spot_check:               :keyword_review,
    low_or_no_suggestion:             :manual_review,
  }.freeze
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

    # Count promotion_detected across ALL buckets (it is orthogonal to bucket type).
    all_rows = buckets.values.sum([], &:itself)

    action_summary = {
      bulk_confirm:       buckets[:single_product_regex_confirmable].size,
      bundle_review:      buckets[:bundle_candidate].size,
      keyword_review:     buckets[:keyword_spot_check].size,
      manual_review:      buckets[:ambiguous_regex_match].size + buckets[:low_or_no_suggestion].size,
      promotion_detected: all_rows.count { |r| r[:promotion_detected] },
    }

    {
      summary:                          summary,
      action_summary:                   action_summary,
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
      action_type:           BUCKET_TO_ACTION_TYPE.fetch(bucket),
      promotion_detected:    mapping.raw_name.match?(PROMOTION_PATTERN),
    }

    # Surface the overlap reason so reviewers know which regex(es) to tighten.
    row[:reason] = "regex_overlap" if bucket == :ambiguous_regex_match

    row
  end
end

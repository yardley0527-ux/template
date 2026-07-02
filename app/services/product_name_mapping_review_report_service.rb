# frozen_string_literal: true

# Bulk Confirm Readiness Report — read-only, zero DB writes.
#
# Classifies all pending ProductNameMappings into four action buckets:
#
#   A. single_product_regex_confirmable
#        High confidence + raw_name matches exactly ONE CrmProduct's regex.
#        Safe to bulk-confirm as-is.
#
#   B. bundle_candidate
#        raw_name matches TWO OR MORE CrmProduct regexes simultaneously.
#        Must NOT be bulk-confirmed — hand off to Bundle Components Parser.
#        (Priority over A/C/D: checked first regardless of suggested_confidence.)
#
#   C. keyword_spot_check
#        High confidence, but raw_name did NOT match any stored regex.
#        Suggestion came from core-keyword, label-segment, or trigram logic.
#        Spot-check a sample before bulk action.
#
#   D. low_or_no_suggestion
#        Medium / Low confidence, or no suggestion at all.
#        Leave for manual review last.
#
# Usage (Rails console):
#   report = ProductNameMappingReviewReportService.call
#   report[:summary]
#   report[:bulk_confirm_readiness]
#   report[:single_product_regex_confirmable].take(20)
#   report[:bundle_candidate].take(20)
#   report[:keyword_spot_check].take(20)
#   report[:low_or_no_suggestion].take(20)
class ProductNameMappingReviewReportService
  def self.call
    new.call
  end

  def call
    # Load all CrmProducts that have a regex (used for bundle detection).
    # Cached once; avoids N+1 inside the classification loop.
    products_with_regex = CrmProduct.where.not(regex_pattern: [nil, ""]).to_a

    # Load all pending mappings, sorted descending by occurrence_count.
    # Order is preserved as rows are pushed into each bucket.
    pending = ProductNameMapping
      .pending
      .includes(:suggested_crm_product)
      .order(occurrence_count: :desc)
      .to_a

    # ── Classify into four buckets ────────────────────────────────────────
    buckets = {
      single_product_regex_confirmable: [],
      bundle_candidate:                 [],
      keyword_spot_check:               [],
      low_or_no_suggestion:             [],
    }

    pending.each do |m|
      bucket = classify(m, products_with_regex)
      buckets[bucket] << build_row(m, products_with_regex)
    end

    # ── Summary ───────────────────────────────────────────────────────────
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
      keyword_spot_check:               buckets[:keyword_spot_check].size,
      low_or_no_suggestion:             buckets[:low_or_no_suggestion].size,
    }

    {
      summary:                          summary,
      bulk_confirm_readiness:           bulk_confirm_readiness,
      single_product_regex_confirmable: buckets[:single_product_regex_confirmable],
      bundle_candidate:                 buckets[:bundle_candidate],
      keyword_spot_check:               buckets[:keyword_spot_check],
      low_or_no_suggestion:             buckets[:low_or_no_suggestion],
    }
  end

  private

  # ── Classification (bundle check has highest priority) ─────────────────

  def classify(mapping, products_with_regex)
    matched = matching_products(mapping.raw_name, products_with_regex)

    return :bundle_candidate if matched.size >= 2

    if mapping.suggested_confidence == "High"
      matched.size == 1 ? :single_product_regex_confirmable : :keyword_spot_check
    else
      :low_or_no_suggestion
    end
  end

  # Returns CrmProducts whose regex_pattern matches raw_name.
  def matching_products(raw_name, products)
    products.select { |p| matches_regex?(raw_name, p.regex_pattern) }
  end

  def matches_regex?(raw_name, pattern)
    raw_name.match?(Regexp.new(pattern))
  rescue RegexpError
    false
  end

  # ── Row builder ────────────────────────────────────────────────────────

  def build_row(mapping, products_with_regex)
    suggested = mapping.suggested_crm_product
    row = {
      raw_name:              mapping.raw_name,
      occurrence_count:      mapping.occurrence_count,
      suggested_crm_product: suggested&.label,
      confidence:            mapping.suggested_confidence,
      source:                mapping.source,
    }

    # For bundle candidates, surface which products were detected — useful
    # for the Bundle Components Parser to know what it needs to split.
    matched = matching_products(mapping.raw_name, products_with_regex)
    row[:matched_products] = matched.map(&:label) if matched.size >= 2

    row
  end
end

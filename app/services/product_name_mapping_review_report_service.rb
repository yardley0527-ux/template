# frozen_string_literal: true

# Read-only report on all pending ProductNameMappings.
#
# Produces a summary (pending totals by confidence) plus a ranked list of the
# top 100 High-confidence entries, with an auto-confirm estimate for each.
#
# Auto-confirm classification:
#   :regex_match   — raw_name matches the suggested product's stored regex_pattern.
#                    Safest to bulk-confirm; the same pattern the generator used.
#   :keyword_match — High confidence but regex does NOT match.  Suggestion came
#                    from core-keyword, label-segment, or trigram logic.  Still
#                    High confidence, but spot-check before bulk action.
#   :none          — No High-confidence suggestion (Medium/Low/nil).
#
# Usage (Rails console):
#   report = ProductNameMappingReviewReportService.call
#   report[:summary]
#   report[:top_100_high].first(10)
#   report[:auto_confirm_estimate]
class ProductNameMappingReviewReportService
  def self.call
    new.call
  end

  def call
    # ── Summary counts (DB aggregates, no full load) ─────────────────────
    pending_scope = ProductNameMapping.pending

    summary = {
      pending_total:        pending_scope.count,
      high_confidence:      pending_scope.where(suggested_confidence: "High").count,
      medium_confidence:    pending_scope.where(suggested_confidence: "Medium").count,
      low_confidence:       pending_scope.where(suggested_confidence: "Low").count,
      no_suggestion:        pending_scope.where(suggested_confidence: nil).count,
    }

    # ── Top 100 High — ranked by occurrence_count DESC ───────────────────
    top_high_rows = ProductNameMapping
      .pending
      .where(suggested_confidence: "High")
      .includes(:suggested_crm_product)
      .order(occurrence_count: :desc)
      .limit(100)
      .map { |m| build_row(m) }

    # ── Auto-confirm estimate across ALL High pending ─────────────────────
    all_high = ProductNameMapping
      .pending
      .where(suggested_confidence: "High")
      .includes(:suggested_crm_product)

    regex_auto    = 0
    keyword_auto  = 0

    all_high.each do |m|
      case classify(m, m.suggested_crm_product)
      when :regex_match   then regex_auto   += 1
      when :keyword_match then keyword_auto += 1
      end
    end

    auto_confirm_estimate = {
      regex_auto_confirmable:   regex_auto,
      keyword_spot_check:       keyword_auto,
      total_high:               summary[:high_confidence],
      note: [
        "regex_auto_confirmable: raw_name matched the suggested product's regex_pattern",
        "— safe to bulk-confirm via ProductNameMapping.pending",
        "  .where(suggested_confidence: 'High') after verifying a sample.",
        "keyword_spot_check: High confidence via keyword/label/trigram logic",
        "— review a few before bulk action.",
      ].join("\n  ")
    }

    {
      summary:               summary,
      auto_confirm_estimate: auto_confirm_estimate,
      top_100_high:          top_high_rows,
    }
  end

  private

  def build_row(mapping)
    product = mapping.suggested_crm_product
    {
      raw_name:              mapping.raw_name,
      occurrence_count:      mapping.occurrence_count,
      suggested_crm_product: product&.label,
      confidence:            mapping.suggested_confidence,
      source:                mapping.source,
      auto_confirmable:      classify(mapping, product),
    }
  end

  def classify(mapping, product)
    return :none unless product&.regex_pattern.present?

    if mapping.raw_name.match?(Regexp.new(product.regex_pattern))
      :regex_match
    else
      :keyword_match
    end
  rescue RegexpError
    :keyword_match
  end
end

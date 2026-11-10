# frozen_string_literal: true

# Epic E3-3: writes ProductMappingComponent rows from ProductQuantityParserService
# output, for confirmed mappings that don't have components yet.
#
# This is strictly ADDITIVE — the reconciliation of mappings that already have
# components (Epic C's rows, where old and new parser may disagree) is E3-4,
# deliberately out of scope here. A mapping with ANY existing component is
# skipped untouched, never merged or overwritten.
#
# A mapping is written only when ALL of:
#   1. mapping_status == "confirmed_alias"
#   2. it has zero existing components
#   3. its raw_name has no overlapping regex spans (the same rule that sends
#      a pending mapping to the ambiguous_regex_match bucket in E1's review
#      report — overlapping matches mean we can't trust per-product quantity
#      attribution, so we refuse to write rather than guess)
#   4. ProductQuantityParserService returns at least one component
#
# dry_run: true  → zero DB writes, returns the full plan (counts, by_product,
#                   top 30 would-write rows) for human review.
# dry_run: false → same plan, then writes every would-write row inside one
#                   transaction; any failure rolls back the entire batch.
#
# Idempotent: rows written on a previous run make their mapping fall into
# skipped_existing on the next run, so re-running never duplicates. The DB
# unique index on (product_name_mapping_id, crm_product_id) is the backstop.
#
# Usage:
#   ProductMappingComponentWriterService.call(dry_run: true)
#   ProductMappingComponentWriterService.call(dry_run: false)
class ProductMappingComponentWriterService
  TOP_ROWS = 30

  # parser: test-only injection seam (same pattern as BulkConfirmService's
  # report:) — production callers never pass it and get the real
  # ProductQuantityParserService.
  def self.call(dry_run:, parser: nil)
    new(dry_run: dry_run, parser: parser).call
  end

  def initialize(dry_run:, parser: nil)
    @dry_run = dry_run
    @parser  = parser || ProductQuantityParserService
  end

  def call
    plan = build_plan
    @dry_run ? plan.merge(dry_run: true) : execute!(plan)
  end

  private

  def build_plan
    confirmed = ProductNameMapping
      .confirmed
      .includes(components: :crm_product)
      .order(:raw_name)
      .to_a

    products      = CrmProduct.where.not(regex_pattern: [nil, ""]).to_a
    product_by_key = products.index_by(&:key)

    skipped_existing = []
    skipped_unparsed = []
    failed_overlap   = []
    would_write      = []

    confirmed.each do |mapping|
      if mapping.components.any?
        skipped_existing << mapping
        next
      end

      matches = ProductNameMappingReviewReportService
        .find_matches_with_spans(mapping.raw_name, products)

      if overlapping_spans?(matches)
        failed_overlap << mapping
        next
      end

      parsed = @parser.call(mapping.raw_name, products: products).components
      if parsed.empty?
        skipped_unparsed << mapping
        next
      end

      would_write << { mapping: mapping, components: parsed }
    end

    {
      total_confirmed:              confirmed.size,
      parsed_count:                 confirmed.size - skipped_unparsed.size,
      unparsed_count:               skipped_unparsed.size,
      already_has_components_count: skipped_existing.size,
      failed_overlap_count:         failed_overlap.size,
      failed_overlap_raw_names:     failed_overlap.map(&:raw_name),
      would_write_count:            would_write.size,
      by_product:                   by_product_summary(would_write),
      top_rows:                     top_rows(would_write),
      product_by_key:               product_by_key,
      would_write:                  would_write,
    }
  end

  def execute!(plan)
    product_by_key   = plan[:product_by_key]
    created_rows     = 0
    written_mappings = 0

    ActiveRecord::Base.transaction do
      plan[:would_write].each do |entry|
        mapping = entry[:mapping]

        # Re-check right before writing — a concurrent writer (legacy
        # bundle_components:write, another run of this task) may have
        # componented this mapping after the plan was built.
        next if mapping.components.reload.any?

        entry[:components].each do |c|
          product = product_by_key.fetch(c[:crm_product_key]) do
            raise "ProductMappingComponentWriterService: parser returned unknown " \
                  "crm_product_key #{c[:crm_product_key].inspect} for #{mapping.raw_name.inspect}"
          end

          ProductMappingComponent.create!(
            product_name_mapping: mapping,
            crm_product:          product,
            paid_quantity:        c[:paid_quantity],
            gift_quantity:        c[:gift_quantity]
          )
          created_rows += 1
        end
        written_mappings += 1
      end
    end

    plan
      .except(:product_by_key, :would_write)
      .merge(dry_run: false, written_mappings: written_mappings, created_rows: created_rows)
  end

  # Same span rule as ProductNameMappingReviewReportService#non_overlapping_spans?
  # (its ambiguous_regex_match bucket): 2+ matches whose character ranges
  # intersect. Single or zero matches can never be ambiguous.
  def overlapping_spans?(matches)
    return false if matches.size < 2

    spans = matches.map { |m| m[:span] }.sort_by(&:begin)
    spans.each_cons(2).any? { |a, b| a.end > b.begin }
  end

  def by_product_summary(would_write)
    would_write.each_with_object({}) do |entry, h|
      entry[:components].each do |c|
        agg = (h[c[:crm_product_label]] ||= { rows: 0, paid: 0, gift: 0 })
        agg[:rows] += 1
        agg[:paid] += c[:paid_quantity]
        agg[:gift] += c[:gift_quantity]
      end
    end
  end

  def top_rows(would_write)
    would_write.first(TOP_ROWS).map do |entry|
      { raw_name: entry[:mapping].raw_name, components: entry[:components] }
    end
  end
end

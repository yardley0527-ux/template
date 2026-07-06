# frozen_string_literal: true

# Epic E2-3: Bulk Confirm Workflow.
#
# Confirms ONLY mappings classified action_type == :bulk_confirm by
# ProductNameMappingReviewReportService (bucket single_product_regex_confirmable).
# Every other bucket (bundle_review / keyword_review / manual_review) is left
# untouched — this service never writes to those.
#
# dry_run: true  → zero DB writes, returns a preview (totals + top 30 rows).
# dry_run: false → per row, inside one transaction: takes SELECT ... FOR UPDATE
#                   on the mapping, re-checks status/action_type/suggested product
#                   against that locked read (not the pre-transaction snapshot),
#                   then confirms + writes history. Any raise rolls back the
#                   entire batch.
#
# The lock is what prevents a lost update against concurrent writers on the
# same table — e.g. ProductRegistryController#confirm / #ignore (manual review
# UI) — racing this batch: whichever transaction gets there first wins, and the
# other observes the fresh post-lock status and skips instead of overwriting it.
#
# Usage:
#   ProductNameMappingBulkConfirmService.call(dry_run: true)
#   ProductNameMappingBulkConfirmService.call(dry_run: false, performed_by_user_id: current_user.id)
class ProductNameMappingBulkConfirmService
  # report: test-only injection seam — production callers never pass it and
  # get the live ProductNameMappingReviewReportService.call result.
  def self.call(dry_run:, performed_by_user_id: nil, report: nil)
    new(dry_run: dry_run, performed_by_user_id: performed_by_user_id, report: report).call
  end

  def initialize(dry_run:, performed_by_user_id: nil, report: nil)
    @dry_run              = dry_run
    @performed_by_user_id = performed_by_user_id
    @report                = report
  end

  def call
    @dry_run ? preview : confirm!
  end

  private

  attr_reader :performed_by_user_id

  # Pulls the single_product_regex_confirmable bucket from the review report
  # (single source of truth for classification). Mapping records are batch-
  # loaded by mapping_id (one query) instead of N per-row lookups.
  #
  # These mapping objects are a snapshot only — used for the preview and to
  # know which ids to lock. confirm! re-fetches each one with a lock before
  # trusting its status.
  def eligible_rows
    report = @report || ProductNameMappingReviewReportService.call
    bucket = report[:single_product_regex_confirmable]

    mappings_by_id = ProductNameMapping.where(id: bucket.map { |row| row[:mapping_id] }).index_by(&:id)

    bucket.filter_map do |row|
      mapping = mappings_by_id[row[:mapping_id]]
      next unless mapping

      { mapping: mapping, row: row }
    end
  end

  def product_label(row)
    row[:suggested_crm_product] || "(none)"
  end

  def preview
    rows = eligible_rows

    by_product = rows.each_with_object(Hash.new(0)) do |r, h|
      h[product_label(r[:row])] += 1
    end

    {
      dry_run:    true,
      total:      rows.size,
      by_product: by_product,
      top_30:     rows.first(30).map { |r| r[:row] },
    }
  end

  def confirm!
    rows             = eligible_rows
    confirmed_count  = 0
    skipped_count    = 0
    failed_count     = 0
    history_written  = 0
    by_product       = Hash.new(0)
    failed_rows      = []

    ActiveRecord::Base.transaction do
      rows.each do |r|
        row = r[:row]

        # Cheap check first — no lock needed to reject a misclassified row.
        unless row[:action_type] == :bulk_confirm
          raise "ProductNameMappingBulkConfirmService: mapping #{r[:mapping].id} " \
                "(#{r[:mapping].raw_name.inspect}) is not action_type bulk_confirm — refusing to confirm"
        end

        # Re-fetch with a row lock — this is the authoritative read. A concurrent
        # writer (e.g. manual review UI) either already committed a non-pending
        # status here (we see it and skip) or is blocked behind our lock until
        # we commit (it then sees OUR committed state, not the reverse).
        mapping = ProductNameMapping.lock.find(r[:mapping].id)

        if mapping.mapping_status != "pending"
          skipped_count += 1
          next
        end

        if mapping.suggested_crm_product_id.blank?
          failed_count += 1
          failed_rows << { raw_name: mapping.raw_name, source: mapping.source,
                            reason: "suggested_crm_product_id is nil" }
          next
        end

        from_status         = mapping.mapping_status
        new_crm_product_id  = mapping.suggested_crm_product_id

        mapping.update!(
          mapping_status:       "confirmed_alias",
          crm_product_id:       new_crm_product_id,
          reviewed_at:          Time.current,
          reviewed_by_user_id:  performed_by_user_id
        )

        ProductNameMappingHistoryService.record!(
          mapping:              mapping,
          action:               :bulk_confirm,
          change_source:        :bulk_confirm,
          from_status:          from_status,
          to_status:            "confirmed_alias",
          new_crm_product_id:   new_crm_product_id,
          performed_by_user_id: performed_by_user_id
        )

        confirmed_count += 1
        history_written += 1
        by_product[product_label(row)] += 1
      end
    end

    {
      confirmed_count: confirmed_count,
      skipped_count:   skipped_count,
      failed_count:    failed_count,
      history_written: history_written,
      by_product:      by_product,
      failed_rows:     failed_rows,
    }
  end
end

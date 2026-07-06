# frozen_string_literal: true

# Epic E2-3: Bulk Confirm Workflow.
#
# Confirms ONLY mappings classified action_type == :bulk_confirm by
# ProductNameMappingReviewReportService (bucket single_product_regex_confirmable).
# Every other bucket (bundle_review / keyword_review / manual_review) is left
# untouched — this service never writes to those.
#
# dry_run: true  → zero DB writes, returns a preview (totals + top 30 rows).
# dry_run: false → wraps every confirm + history write in one transaction;
#                   any failure rolls back the entire batch.
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
  # (single source of truth for classification) and resolves each row back
  # to its live ProductNameMapping record via the raw_name+source unique key.
  def eligible_rows
    report = @report || ProductNameMappingReviewReportService.call
    report[:single_product_regex_confirmable].filter_map do |row|
      mapping = ProductNameMapping.find_by(raw_name: row[:raw_name], source: row[:source])
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
    history_written  = 0
    by_product       = Hash.new(0)

    ActiveRecord::Base.transaction do
      rows.each do |r|
        mapping = r[:mapping]

        unless r[:row][:action_type] == :bulk_confirm
          raise "ProductNameMappingBulkConfirmService: mapping #{mapping.id} " \
                "(#{mapping.raw_name.inspect}) is not action_type bulk_confirm — refusing to confirm"
        end

        if mapping.mapping_status != "pending"
          skipped_count += 1
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
        by_product[product_label(r[:row])] += 1
      end
    end

    {
      confirmed_count: confirmed_count,
      skipped_count:   skipped_count,
      history_written: history_written,
      by_product:      by_product,
    }
  end
end

# frozen_string_literal: true

require "test_helper"

class ProductNameMappingBulkConfirmServiceTest < ActiveSupport::TestCase
  setup do
    @metabolism = CrmProduct.create!(
      key: "test_metabolism", label: "代謝錠", status: "confirmed",
      include_in_analysis: false, source: "test", regex_pattern: "代謝錠"
    )
    @user = users(:one)
  end

  def create_bulk_confirmable(raw_name, crm_product: @metabolism, source: "shopline_order", occurrence_count: 1)
    ProductNameMapping.create!(
      raw_name:             raw_name,
      source:               source,
      mapping_status:       "pending",
      occurrence_count:     occurrence_count,
      suggested_crm_product: crm_product,
      suggested_confidence: "High"
    )
  end

  test "dry_run does not write to the database" do
    mapping = create_bulk_confirmable("代謝錠2")

    result = ProductNameMappingBulkConfirmService.call(dry_run: true)

    assert_equal 1,                     result[:total]
    assert_equal({ "代謝錠" => 1 },      result[:by_product])
    assert_equal "pending",             mapping.reload.mapping_status
    assert_equal 0,                     ProductNameMappingLog.count
  end

  test "dry_run lists eligible rows for manual review" do
    3.times { |i| create_bulk_confirmable("代謝錠#{i}") }

    result = ProductNameMappingBulkConfirmService.call(dry_run: true)

    assert_equal 3, result[:top_30].size
    assert result[:top_30].all? { |r| r[:action_type] == :bulk_confirm }
  end

  test "confirms eligible mappings and writes history in one transaction" do
    mapping = create_bulk_confirmable("代謝錠2")

    result = ProductNameMappingBulkConfirmService.call(dry_run: false, performed_by_user_id: @user.id)

    mapping.reload
    assert_equal "confirmed_alias", mapping.mapping_status
    assert_equal @metabolism.id,    mapping.crm_product_id
    assert_equal @user.id,          mapping.reviewed_by_user_id
    assert_not_nil                  mapping.reviewed_at

    assert_equal 1,                 result[:confirmed_count]
    assert_equal 0,                 result[:skipped_count]
    assert_equal 1,                 result[:history_written]
    assert_equal({ "代謝錠" => 1 },  result[:by_product])

    assert_equal 1, mapping.mapping_logs.count
    log = mapping.mapping_logs.first
    assert_equal 1,                 log.mapping_version
    assert_equal "bulk_confirm",    log.action
    assert_equal "bulk_confirm",    log.change_source
    assert_equal "pending",         log.from_status
    assert_equal "confirmed_alias", log.to_status
    assert_equal @metabolism.id,    log.new_crm_product_id
    assert_equal @user.id,          log.performed_by_user_id
  end

  test "confirms mappings even when promotion_detected is true" do
    mapping = create_bulk_confirmable("代謝錠2送1")

    report = ProductNameMappingReviewReportService.call
    row    = report[:single_product_regex_confirmable].find { |r| r[:raw_name] == mapping.raw_name }
    assert row[:promotion_detected], "expected fixture raw_name to trip promotion detection"

    result = ProductNameMappingBulkConfirmService.call(dry_run: false, performed_by_user_id: @user.id)

    assert_equal 1, result[:confirmed_count]
    assert_equal "confirmed_alias", mapping.reload.mapping_status
  end

  test "does not confirm mappings outside the single_product_regex_confirmable bucket" do
    glutathione = CrmProduct.create!(
      key: "test_glutathione", label: "穀胱甘肽", status: "confirmed",
      include_in_analysis: false, source: "test", regex_pattern: "穀胱甘肽"
    )
    bundle_mapping = ProductNameMapping.create!(
      raw_name:             "代謝錠+穀胱甘肽",
      source:               "shopline_order",
      mapping_status:       "pending",
      occurrence_count:     1,
      suggested_confidence: "High"
    )

    result = ProductNameMappingBulkConfirmService.call(dry_run: false, performed_by_user_id: @user.id)

    assert_equal 0, result[:confirmed_count]
    assert_equal "pending", bundle_mapping.reload.mapping_status
    assert_equal 0, ProductNameMappingLog.where(product_name_mapping_id: bundle_mapping.id).count
  end

  test "skips mappings whose status is no longer pending by the time they are processed" do
    mapping = create_bulk_confirmable("代謝錠2")
    mapping.update_column(:mapping_status, "ignored")

    stubbed_report = {
      single_product_regex_confirmable: [
        {
          mapping_id:            mapping.id,
          raw_name:              mapping.raw_name,
          source:                mapping.source,
          suggested_crm_product: @metabolism.label,
          occurrence_count:      1,
          action_type:           :bulk_confirm,
          promotion_detected:    false,
        },
      ],
    }

    result = ProductNameMappingBulkConfirmService.call(
      dry_run: false, performed_by_user_id: @user.id, report: stubbed_report
    )

    assert_equal 0, result[:confirmed_count]
    assert_equal 1, result[:skipped_count]
    assert_equal 0, result[:history_written]

    assert_equal "ignored", mapping.reload.mapping_status
    assert_equal 0, ProductNameMappingLog.count
  end

  test "re-checks status under lock at write time, not the pre-transaction snapshot" do
    # Simulates ProductRegistryController#ignore committing between the report
    # snapshot and this service's write — the row lock + fresh read must catch it.
    mapping = create_bulk_confirmable("代謝錠2")

    stubbed_report = {
      single_product_regex_confirmable: [
        {
          mapping_id:            mapping.id,
          raw_name:              mapping.raw_name,
          source:                mapping.source,
          suggested_crm_product: @metabolism.label,
          occurrence_count:      1,
          action_type:           :bulk_confirm,
          promotion_detected:    false,
        },
      ],
    }

    # Concurrent writer (e.g. ProductRegistryController#ignore) commits *after*
    # the snapshot above was built, but before this service runs — it must read
    # this committed value under lock rather than trusting the stale snapshot.
    mapping.update_column(:mapping_status, "ignored")

    result = ProductNameMappingBulkConfirmService.call(
      dry_run: false, performed_by_user_id: @user.id, report: stubbed_report
    )

    assert_equal 0, result[:confirmed_count]
    assert_equal 1, result[:skipped_count]
    assert_equal "ignored", mapping.reload.mapping_status
    assert_equal 0, ProductNameMappingLog.count
  end

  test "raises and rolls back the whole batch if a row is misclassified" do
    good = create_bulk_confirmable("代謝錠2")
    bad  = create_bulk_confirmable("代謝錠3")

    stubbed_report = {
      single_product_regex_confirmable: [
        {
          mapping_id: good.id, raw_name: good.raw_name, source: good.source,
          suggested_crm_product: @metabolism.label, occurrence_count: 1,
          action_type: :bulk_confirm, promotion_detected: false,
        },
        {
          mapping_id: bad.id, raw_name: bad.raw_name, source: bad.source,
          suggested_crm_product: @metabolism.label, occurrence_count: 1,
          action_type: :manual_review, promotion_detected: false,
        },
      ],
    }

    assert_raises(RuntimeError) do
      ProductNameMappingBulkConfirmService.call(
        dry_run: false, performed_by_user_id: @user.id, report: stubbed_report
      )
    end

    assert_equal "pending", good.reload.mapping_status
    assert_equal "pending", bad.reload.mapping_status
    assert_equal 0, ProductNameMappingLog.count
  end

  test "does not confirm and counts as failed when suggested_crm_product_id is nil" do
    mapping = ProductNameMapping.create!(
      raw_name:             "代謝錠4",
      source:               "shopline_order",
      mapping_status:       "pending",
      occurrence_count:     1,
      suggested_confidence: "High"
      # suggested_crm_product intentionally absent — data anomaly: High
      # confidence with no suggested product.
    )

    stubbed_report = {
      single_product_regex_confirmable: [
        {
          mapping_id: mapping.id, raw_name: mapping.raw_name, source: mapping.source,
          suggested_crm_product: nil, occurrence_count: 1,
          action_type: :bulk_confirm, promotion_detected: false,
        },
      ],
    }

    result = ProductNameMappingBulkConfirmService.call(
      dry_run: false, performed_by_user_id: @user.id, report: stubbed_report
    )

    assert_equal 0, result[:confirmed_count]
    assert_equal 1, result[:failed_count]
    assert_equal 0, result[:history_written]
    assert_equal [{
      mapping_id:               mapping.id,
      raw_name:                 "代謝錠4",
      source:                   "shopline_order",
      suggested_confidence:     "High",
      suggested_crm_product_id: nil,
      reason:                   "suggested_crm_product_id is nil",
    }], result[:failed_rows]

    mapping.reload
    assert_equal "pending", mapping.mapping_status
    assert_nil mapping.crm_product_id
    assert_equal 0, ProductNameMappingLog.count
  end

  test "review report rows carry mapping_id for batched lookup" do
    mapping = create_bulk_confirmable("代謝錠2")

    report = ProductNameMappingReviewReportService.call
    row    = report[:single_product_regex_confirmable].find { |r| r[:raw_name] == mapping.raw_name }

    assert_equal mapping.id, row[:mapping_id]
  end
end

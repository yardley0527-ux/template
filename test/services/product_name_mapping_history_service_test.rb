# frozen_string_literal: true

require "test_helper"

class ProductNameMappingHistoryServiceTest < ActiveSupport::TestCase
  setup do
    @mapping = ProductNameMapping.create!(
      raw_name:       "代謝錠1",
      source:         "shopline_order",
      mapping_status: "pending"
    )
  end

  test "creates a log with mapping_version=1 for the first event" do
    log = ProductNameMappingHistoryService.record!(
      mapping:       @mapping,
      action:        :bulk_confirm,
      change_source: :bulk_confirm,
      from_status:   "pending",
      to_status:     "confirmed_alias"
    )

    assert_equal 1,                 log.mapping_version
    assert_equal "bulk_confirm",    log.action
    assert_equal "bulk_confirm",    log.change_source
    assert_equal "pending",         log.from_status
    assert_equal "confirmed_alias", log.to_status
    assert_not_nil                  log.created_at
  end

  test "increments mapping_version for each subsequent event" do
    ProductNameMappingHistoryService.record!(
      mapping: @mapping, action: :confirm, change_source: :manual_ui,
      from_status: "pending", to_status: "confirmed_alias"
    )

    log2 = ProductNameMappingHistoryService.record!(
      mapping: @mapping, action: :undo, change_source: :manual_ui,
      from_status: "confirmed_alias", to_status: "pending"
    )

    log3 = ProductNameMappingHistoryService.record!(
      mapping: @mapping, action: :confirm, change_source: :manual_ui,
      from_status: "pending", to_status: "confirmed_alias"
    )

    assert_equal 2, log2.mapping_version
    assert_equal 3, log3.mapping_version
  end

  test "mapping_version is independent per mapping" do
    other_mapping = ProductNameMapping.create!(
      raw_name:       "薑黃1",
      source:         "shopline_order",
      mapping_status: "pending"
    )

    ProductNameMappingHistoryService.record!(
      mapping: @mapping, action: :confirm, change_source: :manual_ui,
      from_status: "pending", to_status: "confirmed_alias"
    )
    ProductNameMappingHistoryService.record!(
      mapping: @mapping, action: :undo, change_source: :manual_ui,
      from_status: "confirmed_alias", to_status: "pending"
    )

    # other_mapping has no prior logs — should start at version 1
    log = ProductNameMappingHistoryService.record!(
      mapping: other_mapping, action: :confirm, change_source: :manual_ui,
      from_status: "pending", to_status: "confirmed_alias"
    )

    assert_equal 1, log.mapping_version
  end

  test "persists optional fields when provided" do
    log = ProductNameMappingHistoryService.record!(
      mapping:              @mapping,
      action:               :bulk_confirm,
      change_source:        :bulk_confirm,
      from_status:          "pending",
      to_status:            "confirmed_alias",
      old_crm_product_id:   nil,
      new_crm_product_id:   42,
      performed_by_user_id: 1,
      notes:                "Bulk confirm via Review Workflow"
    )

    assert_equal 42,                                log.new_crm_product_id
    assert_equal 1,                                 log.performed_by_user_id
    assert_equal "Bulk confirm via Review Workflow", log.notes
    assert_nil                                      log.old_crm_product_id
  end

  test "optional fields default to nil" do
    log = ProductNameMappingHistoryService.record!(
      mapping: @mapping, action: :ignore, change_source: :system,
      from_status: "pending", to_status: "ignored"
    )

    assert_nil log.old_crm_product_id
    assert_nil log.new_crm_product_id
    assert_nil log.performed_by_user_id
    assert_nil log.notes
  end

  test "accepts symbol or string for action and change_source" do
    log_sym = ProductNameMappingHistoryService.record!(
      mapping: @mapping, action: :confirm, change_source: :manual_ui,
      from_status: "pending", to_status: "confirmed_alias"
    )
    assert_equal "confirm",   log_sym.action
    assert_equal "manual_ui", log_sym.change_source
  end

  test "raises on invalid action" do
    assert_raises(ActiveRecord::RecordInvalid) do
      ProductNameMappingHistoryService.record!(
        mapping: @mapping, action: :nonexistent, change_source: :manual_ui,
        from_status: "pending", to_status: "confirmed_alias"
      )
    end
  end

  test "mapping has_many mapping_logs returns the created logs" do
    ProductNameMappingHistoryService.record!(
      mapping: @mapping, action: :confirm, change_source: :manual_ui,
      from_status: "pending", to_status: "confirmed_alias"
    )
    ProductNameMappingHistoryService.record!(
      mapping: @mapping, action: :undo, change_source: :manual_ui,
      from_status: "confirmed_alias", to_status: "pending"
    )

    assert_equal 2, @mapping.mapping_logs.count
    assert_equal [1, 2], @mapping.mapping_logs.order(:mapping_version).pluck(:mapping_version)
  end

  test "next_mapping_version returns 1 when no logs exist" do
    assert_equal 1, @mapping.next_mapping_version
  end

  test "next_mapping_version increments after each log" do
    assert_equal 1, @mapping.next_mapping_version

    ProductNameMappingHistoryService.record!(
      mapping: @mapping, action: :confirm, change_source: :manual_ui,
      from_status: "pending", to_status: "confirmed_alias"
    )
    assert_equal 2, @mapping.next_mapping_version

    ProductNameMappingHistoryService.record!(
      mapping: @mapping, action: :undo, change_source: :manual_ui,
      from_status: "confirmed_alias", to_status: "pending"
    )
    assert_equal 3, @mapping.next_mapping_version
  end
end

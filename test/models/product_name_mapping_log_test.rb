# frozen_string_literal: true

require "test_helper"

class ProductNameMappingLogTest < ActiveSupport::TestCase
  setup do
    @mapping = ProductNameMapping.create!(
      raw_name:       "全能1",
      source:         "shopline_order",
      mapping_status: "pending"
    )
  end

  test "persists all required fields" do
    log = ProductNameMappingLog.create!(
      product_name_mapping: @mapping,
      mapping_version:      1,
      action:               "bulk_confirm",
      change_source:        "bulk_confirm",
      from_status:          "pending",
      to_status:            "confirmed_alias"
    )

    assert_equal 1,                  log.mapping_version
    assert_equal "bulk_confirm",     log.action
    assert_equal "bulk_confirm",     log.change_source
    assert_equal "pending",          log.from_status
    assert_equal "confirmed_alias",  log.to_status
    assert_not_nil                   log.created_at
    assert_not_nil                   log.updated_at
  end

  test "action enum predicate methods work" do
    log = ProductNameMappingLog.create!(
      product_name_mapping: @mapping,
      mapping_version: 1, action: "confirm", change_source: "manual_ui",
      from_status: "pending", to_status: "confirmed_alias"
    )

    assert log.confirm?
    assert_not log.bulk_confirm?
    assert_not log.ignore?
  end

  test "change_source enum predicate uses source_ prefix" do
    log = ProductNameMappingLog.create!(
      product_name_mapping: @mapping,
      mapping_version: 1, action: "bulk_confirm", change_source: "bulk_confirm",
      from_status: "pending", to_status: "confirmed_alias"
    )

    assert log.source_bulk_confirm?
    assert_not log.source_manual_ui?
  end

  test "action and change_source can both be bulk_confirm without collision" do
    log = ProductNameMappingLog.create!(
      product_name_mapping: @mapping,
      mapping_version: 1, action: "bulk_confirm", change_source: "bulk_confirm",
      from_status: "pending", to_status: "confirmed_alias"
    )

    assert log.bulk_confirm?          # action predicate
    assert log.source_bulk_confirm?   # change_source predicate (prefixed)
  end

  test "system change_source uses source_ prefix to avoid Ruby keyword conflict" do
    log = ProductNameMappingLog.create!(
      product_name_mapping: @mapping,
      mapping_version: 1, action: "ignore", change_source: "system",
      from_status: "pending", to_status: "ignored"
    )

    assert log.source_system?
  end

  test "optional fields may be nil" do
    log = ProductNameMappingLog.create!(
      product_name_mapping: @mapping,
      mapping_version: 1, action: "confirm", change_source: "manual_ui",
      from_status: "pending", to_status: "confirmed_alias"
    )

    assert_nil log.old_crm_product_id
    assert_nil log.new_crm_product_id
    assert_nil log.performed_by_user_id
    assert_nil log.notes
  end

  test "belongs_to product_name_mapping" do
    log = ProductNameMappingLog.create!(
      product_name_mapping: @mapping,
      mapping_version: 1, action: "confirm", change_source: "manual_ui",
      from_status: "pending", to_status: "confirmed_alias"
    )

    assert_equal @mapping.id, log.product_name_mapping_id
  end

  test "validates required fields" do
    log = ProductNameMappingLog.new(product_name_mapping: @mapping)
    assert_not log.valid?
    assert_includes log.errors[:action],          "can't be blank"
    assert_includes log.errors[:change_source],   "can't be blank"
    assert_includes log.errors[:from_status],     "can't be blank"
    assert_includes log.errors[:to_status],       "can't be blank"
    assert_includes log.errors[:mapping_version], "can't be blank"
  end

  test "rejects invalid action value" do
    # Rails 7.1 enum raises ArgumentError at assignment time, before validation.
    assert_raises(ArgumentError) do
      ProductNameMappingLog.new(
        product_name_mapping: @mapping,
        mapping_version: 1, action: "totally_wrong", change_source: "manual_ui",
        from_status: "pending", to_status: "confirmed_alias"
      )
    end
  end

  test "rejects invalid change_source value" do
    # Rails 7.1 enum raises ArgumentError at assignment time, before validation.
    assert_raises(ArgumentError) do
      ProductNameMappingLog.new(
        product_name_mapping: @mapping,
        mapping_version: 1, action: "confirm", change_source: "unknown_source",
        from_status: "pending", to_status: "confirmed_alias"
      )
    end
  end

  test "rejects mapping_version <= 0" do
    log = ProductNameMappingLog.new(
      product_name_mapping: @mapping,
      mapping_version: 0, action: "confirm", change_source: "manual_ui",
      from_status: "pending", to_status: "confirmed_alias"
    )
    assert_not log.valid?
    assert_includes log.errors[:mapping_version], "must be greater than 0"
  end

  test "all valid action values are accepted" do
    %w[confirm ignore undo bulk_confirm bulk_ignore].each_with_index do |act, i|
      log = ProductNameMappingLog.new(
        product_name_mapping: @mapping,
        mapping_version: i + 1, action: act, change_source: "manual_ui",
        from_status: "pending", to_status: "confirmed_alias"
      )
      assert log.valid?, "Expected #{act} to be valid, got: #{log.errors.full_messages}"
    end
  end

  test "all valid change_source values are accepted" do
    %w[bulk_confirm bulk_ignore manual_ui migration bundle_parser api system].each_with_index do |src, i|
      log = ProductNameMappingLog.new(
        product_name_mapping: @mapping,
        mapping_version: i + 1, action: "confirm", change_source: src,
        from_status: "pending", to_status: "confirmed_alias"
      )
      assert log.valid?, "Expected #{src} to be valid, got: #{log.errors.full_messages}"
    end
  end
end

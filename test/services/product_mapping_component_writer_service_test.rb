# frozen_string_literal: true

require "test_helper"

class ProductMappingComponentWriterServiceTest < ActiveSupport::TestCase
  setup do
    @omnipotent  = create_product("omnipotent",  "全能",     '全能(\d+)')
    @metabolism  = create_product("metabolism",  "代謝錠",   '代謝錠?(\d+)')
    @glutathione = create_product("glutathione", "穀胱甘肽", '穀胱甘肽(\d+)')
    @mask        = create_product("mask",        "面膜",     '面膜(\d+)')
  end

  def create_product(key, label, regex_pattern)
    CrmProduct.create!(
      key: "wr_#{key}", label: label, status: "confirmed",
      include_in_analysis: false, source: "test", regex_pattern: regex_pattern
    )
  end

  def confirmed_mapping(raw_name)
    ProductNameMapping.create!(
      raw_name: raw_name, source: "shopline_order",
      mapping_status: "confirmed_alias", occurrence_count: 1
    )
  end

  test "dry_run computes the plan with zero DB writes" do
    confirmed_mapping("全能6")
    confirmed_mapping("完全match不到的字串ZZZ")

    result = nil
    assert_no_difference -> { ProductMappingComponent.count } do
      result = ProductMappingComponentWriterService.call(dry_run: true)
    end

    assert result[:dry_run]
    assert_equal 2, result[:total_confirmed]
    assert_equal 1, result[:parsed_count]
    assert_equal 1, result[:unparsed_count]
    assert_equal 0, result[:already_has_components_count]
    assert_equal 1, result[:would_write_count]
    assert_equal({ "全能" => { rows: 1, paid: 6, gift: 0 } }, result[:by_product])
    assert_equal "全能6", result[:top_rows].first[:raw_name]
  end

  test "writes a single-product component" do
    mapping = confirmed_mapping("全能6")

    result = ProductMappingComponentWriterService.call(dry_run: false)

    assert_equal 1, result[:written_mappings]
    assert_equal 1, result[:created_rows]

    component = mapping.components.reload.sole
    assert_equal @omnipotent.id, component.crm_product_id
    assert_equal 6, component.paid_quantity
    assert_equal 0, component.gift_quantity
  end

  test "writes multi-product bundle components" do
    mapping = confirmed_mapping("代謝錠2全能3")

    result = ProductMappingComponentWriterService.call(dry_run: false)

    assert_equal 1, result[:written_mappings]
    assert_equal 2, result[:created_rows]

    by_key = mapping.components.reload.index_by { |c| c.crm_product.key }
    assert_equal 2, by_key["wr_metabolism"].paid_quantity
    assert_equal 3, by_key["wr_omnipotent"].paid_quantity
  end

  test "writes gift_quantity, including a wholly-gifted second product" do
    mapping = confirmed_mapping("穀胱甘肽10送2送面膜1")

    ProductMappingComponentWriterService.call(dry_run: false)

    by_key = mapping.components.reload.index_by { |c| c.crm_product.key }
    assert_equal 10, by_key["wr_glutathione"].paid_quantity
    assert_equal 2,  by_key["wr_glutathione"].gift_quantity
    assert_equal 0,  by_key["wr_mask"].paid_quantity
    assert_equal 1,  by_key["wr_mask"].gift_quantity
  end

  test "total_quantity generated column is computed by the DB" do
    mapping = confirmed_mapping("全能10送2")

    ProductMappingComponentWriterService.call(dry_run: false)

    assert_equal 12, mapping.components.reload.sole.total_quantity
  end

  test "skips mappings that already have components and never touches their rows" do
    mapping = confirmed_mapping("代謝錠12送全能2")
    # Epic C wrote this (with its known gift-misattribution) — E3-3 must not touch it.
    legacy = ProductMappingComponent.create!(
      product_name_mapping: mapping, crm_product: @omnipotent, paid_quantity: 2, gift_quantity: 0
    )

    result = ProductMappingComponentWriterService.call(dry_run: false)

    assert_equal 1, result[:already_has_components_count]
    assert_equal 0, result[:would_write_count]
    assert_equal 0, result[:created_rows]
    assert_equal [legacy.id], mapping.components.reload.ids
    assert_equal 2, legacy.reload.paid_quantity
  end

  test "unparsed mappings are skipped, never force-written" do
    mapping = confirmed_mapping("完全match不到的字串ZZZ")

    result = ProductMappingComponentWriterService.call(dry_run: false)

    assert_equal 1, result[:unparsed_count]
    assert_equal 0, result[:created_rows]
    assert_equal 0, mapping.components.reload.count
  end

  test "idempotent: re-running creates nothing new" do
    confirmed_mapping("全能6")
    confirmed_mapping("代謝錠2全能3")

    first  = ProductMappingComponentWriterService.call(dry_run: false)
    second = ProductMappingComponentWriterService.call(dry_run: false)

    assert_equal 3, first[:created_rows]
    assert_equal 0, second[:created_rows]
    assert_equal 2, second[:already_has_components_count]
    assert_equal 0, second[:would_write_count]
    assert_equal 3, ProductMappingComponent.count
  end

  test "any failure rolls back the whole batch" do
    good = confirmed_mapping("全能6")
    bad  = confirmed_mapping("代謝錠2")

    # Injected parser: valid components for the first mapping, an invalid
    # (0/0 → RecordInvalid) component for the second.
    broken_parser = Class.new do
      define_method(:call) do |raw_name, products: nil|
        components = if raw_name == "全能6"
          [{ crm_product_key: "wr_omnipotent", crm_product_label: "全能",
             paid_quantity: 6, gift_quantity: 0, total_quantity: 6 }]
        else
          [{ crm_product_key: "wr_metabolism", crm_product_label: "代謝錠",
             paid_quantity: 0, gift_quantity: 0, total_quantity: 0 }]
        end
        ProductQuantityParserService::Result.new(components: components)
      end
    end.new

    assert_raises(ActiveRecord::RecordInvalid) do
      ProductMappingComponentWriterService.call(dry_run: false, parser: broken_parser)
    end

    assert_equal 0, ProductMappingComponent.count
    assert_equal 0, good.components.reload.count
    assert_equal 0, bad.components.reload.count
  end

  test "overlap-ambiguous mappings are failed, not written" do
    # Two regexes whose matches overlap on the same characters: 美白3 matches
    # both 美白(\d+) (span 0...3) and 白(\d+) (span 1...3).
    create_product("whitening", "美白", '美白(\d+)')
    create_product("white",     "白",   '白(\d+)')
    mapping = confirmed_mapping("美白3")

    result = ProductMappingComponentWriterService.call(dry_run: false)

    assert_equal 1, result[:failed_overlap_count]
    assert_equal ["美白3"], result[:failed_overlap_raw_names]
    assert_equal 0, result[:would_write_count]
    assert_equal 0, mapping.components.reload.count
  end

  test "non-overlapping multi-match is NOT flagged as overlap (bundle writes normally)" do
    mapping = confirmed_mapping("薑黃1全能1")
    create_product("turmeric", "薑黃", '薑黃(\d+)')

    result = ProductMappingComponentWriterService.call(dry_run: false)

    assert_equal 0, result[:failed_overlap_count]
    assert_equal 2, mapping.components.reload.count
  end
end

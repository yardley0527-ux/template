# frozen_string_literal: true

require "test_helper"

class ProductQuantityParserDryRunReportServiceTest < ActiveSupport::TestCase
  setup do
    @omnipotent = CrmProduct.create!(
      key: "dr_omnipotent", label: "全能", status: "confirmed",
      include_in_analysis: false, source: "test", regex_pattern: '全能(\d+)'
    )
    @metabolism = CrmProduct.create!(
      key: "dr_metabolism", label: "代謝錠", status: "confirmed",
      include_in_analysis: false, source: "test", regex_pattern: '代謝錠?(\d+)'
    )
  end

  def confirmed_mapping(raw_name)
    ProductNameMapping.create!(
      raw_name: raw_name, source: "shopline_order", mapping_status: "confirmed_alias",
      occurrence_count: 1, crm_product: @omnipotent
    )
  end

  test "counts confirmed mappings and flags ones the parser can't match" do
    confirmed_mapping("全能1")
    confirmed_mapping("完全match不到的字串ZZZ")

    result = ProductQuantityParserDryRunReportService.call

    assert_equal 2, result[:total_confirmed]
    assert_equal 1, result[:total_unparsed]
    assert_equal ["完全match不到的字串ZZZ"], result[:unparsed_raw_names]
  end

  test "mapping with no existing components does not appear in diffs" do
    confirmed_mapping("全能1")

    result = ProductQuantityParserDryRunReportService.call

    assert_equal 0, result[:already_componented]
    assert_equal [], result[:diffs]
  end

  test "diffs a mapping whose existing component disagrees with the new parser" do
    mapping = confirmed_mapping("代謝錠12送全能2")
    # Simulate Epic C's old parser output: it has no gift concept, so it
    # wrote omnipotent as fully paid instead of fully gift.
    ProductMappingComponent.create!(
      product_name_mapping: mapping, crm_product: @metabolism, paid_quantity: 12, gift_quantity: 0
    )
    ProductMappingComponent.create!(
      product_name_mapping: mapping, crm_product: @omnipotent, paid_quantity: 2, gift_quantity: 0
    )

    result = ProductQuantityParserDryRunReportService.call

    assert_equal 1, result[:already_componented]
    assert_equal 1, result[:diffs].size

    diff = result[:diffs].first
    assert_equal "代謝錠12送全能2", diff[:raw_name]
    assert diff[:contains_promotion_marker]
    assert_equal({ paid: 2, gift: 0 }, diff[:old_state]["dr_omnipotent"])
    assert_equal({ paid: 0, gift: 2 }, diff[:new_state]["dr_omnipotent"])
  end

  test "diffs_with_promotion only includes raw_names containing 送/贈" do
    with_promo = confirmed_mapping("代謝錠12送全能2")
    ProductMappingComponent.create!(
      product_name_mapping: with_promo, crm_product: @metabolism, paid_quantity: 99, gift_quantity: 0
    )

    result = ProductQuantityParserDryRunReportService.call

    assert_equal result[:diffs].size, result[:diffs_with_promotion].size
    assert result[:diffs_with_promotion].all? { |d| d[:contains_promotion_marker] }
  end

  test "identical old and new state produces no diff" do
    mapping = confirmed_mapping("全能1")
    ProductMappingComponent.create!(
      product_name_mapping: mapping, crm_product: @omnipotent, paid_quantity: 1, gift_quantity: 0
    )

    result = ProductQuantityParserDryRunReportService.call

    assert_equal 1, result[:already_componented]
    assert_equal [], result[:diffs]
  end

  test "does not write to the database" do
    confirmed_mapping("全能1")

    assert_no_difference -> { ProductMappingComponent.count } do
      ProductQuantityParserDryRunReportService.call
    end
  end

  test "flat summary keys are present and consistent with the detailed keys" do
    confirmed_mapping("全能1")                       # parseable, no components
    confirmed_mapping("完全match不到的字串ZZZ")        # unparsed
    with_comp = confirmed_mapping("代謝錠12送全能2")   # componented + diff + gift marker
    ProductMappingComponent.create!(
      product_name_mapping: with_comp, crm_product: @metabolism, paid_quantity: 12, gift_quantity: 0
    )
    ProductMappingComponent.create!(
      product_name_mapping: with_comp, crm_product: @omnipotent, paid_quantity: 2, gift_quantity: 0
    )

    result = ProductQuantityParserDryRunReportService.call

    summary = result.slice(:total_confirmed, :parsed_count, :unparsed_count,
                           :already_has_components_count, :would_write_count,
                           :diff_count, :gift_diff_count)
    assert_equal(
      { total_confirmed: 3, parsed_count: 2, unparsed_count: 1,
        already_has_components_count: 1, would_write_count: 1,
        diff_count: 1, gift_diff_count: 1 },
      summary
    )

    # Aliases must always mirror the detailed keys.
    assert_equal result[:total_unparsed],                result[:unparsed_count]
    assert_equal result[:already_componented],           result[:already_has_components_count]
    assert_equal result[:would_write_new_count],         result[:would_write_count]
    assert_equal result[:diffs].size,                    result[:diff_count]
    assert_equal result[:diffs_with_promotion].size,     result[:gift_diff_count]
    assert_equal result[:total_confirmed] - result[:unparsed_count], result[:parsed_count]
  end
end

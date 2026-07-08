# frozen_string_literal: true

require "test_helper"

class ProductNameMappingTest < ActiveSupport::TestCase
  setup do
    @omnipotent = CrmProduct.create!(
      key: "test_omnipotent2", label: "全能", status: "confirmed",
      include_in_analysis: false, source: "test"
    )
    @turmeric = CrmProduct.create!(
      key: "test_turmeric2", label: "薑黃", status: "confirmed",
      include_in_analysis: false, source: "test"
    )
  end

  test "bundle? is false for a mapping with zero components" do
    mapping = ProductNameMapping.create!(
      raw_name: "全能6_nocomp", source: "shopline_order", mapping_status: "pending", occurrence_count: 1
    )

    assert_not mapping.bundle?
  end

  test "bundle? is false for a mapping with exactly one component (Epic E3: component != bundle)" do
    mapping = ProductNameMapping.create!(
      raw_name: "全能6", source: "shopline_order", mapping_status: "pending", occurrence_count: 1
    )
    ProductMappingComponent.create!(
      product_name_mapping: mapping, crm_product: @omnipotent, paid_quantity: 6, gift_quantity: 0
    )

    assert_not mapping.bundle?
    assert_equal 1, mapping.components.count
  end

  test "bundle? is true for a mapping with two or more components" do
    mapping = ProductNameMapping.create!(
      raw_name: "薑黃1全能1", source: "shopline_order", mapping_status: "pending", occurrence_count: 1
    )
    ProductMappingComponent.create!(
      product_name_mapping: mapping, crm_product: @omnipotent, paid_quantity: 1, gift_quantity: 0
    )
    ProductMappingComponent.create!(
      product_name_mapping: mapping, crm_product: @turmeric, paid_quantity: 1, gift_quantity: 0
    )

    assert mapping.bundle?
  end

  test "bundles scope excludes single-component mappings" do
    single = ProductNameMapping.create!(
      raw_name: "全能6_scope", source: "shopline_order", mapping_status: "pending", occurrence_count: 1
    )
    ProductMappingComponent.create!(
      product_name_mapping: single, crm_product: @omnipotent, paid_quantity: 6, gift_quantity: 0
    )

    bundle = ProductNameMapping.create!(
      raw_name: "薑黃1全能1_scope", source: "shopline_order", mapping_status: "pending", occurrence_count: 1
    )
    ProductMappingComponent.create!(
      product_name_mapping: bundle, crm_product: @omnipotent, paid_quantity: 1, gift_quantity: 0
    )
    ProductMappingComponent.create!(
      product_name_mapping: bundle, crm_product: @turmeric, paid_quantity: 1, gift_quantity: 0
    )

    result_ids = ProductNameMapping.bundles.map(&:id)
    assert_includes result_ids, bundle.id
    assert_not_includes result_ids, single.id
  end
end

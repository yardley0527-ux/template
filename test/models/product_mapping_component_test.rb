# frozen_string_literal: true

require "test_helper"

class ProductMappingComponentTest < ActiveSupport::TestCase
  setup do
    @mapping = ProductNameMapping.create!(
      raw_name: "全能6", source: "shopline_order", mapping_status: "pending", occurrence_count: 1
    )
    @omnipotent = CrmProduct.create!(
      key: "test_omnipotent", label: "全能", status: "confirmed",
      include_in_analysis: false, source: "test"
    )
    @mask = CrmProduct.create!(
      key: "test_mask", label: "面膜", status: "confirmed",
      include_in_analysis: false, source: "test"
    )
  end

  test "single-product component: paid_quantity only, total_quantity computed" do
    component = ProductMappingComponent.create!(
      product_name_mapping: @mapping, crm_product: @omnipotent,
      paid_quantity: 6, gift_quantity: 0
    )

    assert_equal 6, component.paid_quantity
    assert_equal 0, component.gift_quantity
    assert_equal 6, component.reload.total_quantity
  end

  test "total_quantity is a generated column that sums paid + gift" do
    component = ProductMappingComponent.create!(
      product_name_mapping: @mapping, crm_product: @omnipotent,
      paid_quantity: 10, gift_quantity: 2
    )

    assert_equal 12, component.reload.total_quantity
  end

  test "pure-gift component: paid_quantity 0 is valid as long as gift_quantity is positive" do
    component = ProductMappingComponent.new(
      product_name_mapping: @mapping, crm_product: @mask,
      paid_quantity: 0, gift_quantity: 1
    )

    assert component.valid?
  end

  test "rejects paid_quantity and gift_quantity both zero" do
    component = ProductMappingComponent.new(
      product_name_mapping: @mapping, crm_product: @omnipotent,
      paid_quantity: 0, gift_quantity: 0
    )

    assert_not component.valid?
    assert_includes component.errors[:base], "paid_quantity and gift_quantity cannot both be zero"
  end

  test "rejects negative paid_quantity" do
    component = ProductMappingComponent.new(
      product_name_mapping: @mapping, crm_product: @omnipotent,
      paid_quantity: -1, gift_quantity: 0
    )

    assert_not component.valid?
    assert_includes component.errors[:paid_quantity], "must be greater than or equal to 0"
  end

  test "rejects negative gift_quantity" do
    component = ProductMappingComponent.new(
      product_name_mapping: @mapping, crm_product: @omnipotent,
      paid_quantity: 1, gift_quantity: -1
    )

    assert_not component.valid?
    assert_includes component.errors[:gift_quantity], "must be greater than or equal to 0"
  end

  test "still enforces one component per product per mapping" do
    ProductMappingComponent.create!(
      product_name_mapping: @mapping, crm_product: @omnipotent,
      paid_quantity: 6, gift_quantity: 0
    )
    duplicate = ProductMappingComponent.new(
      product_name_mapping: @mapping, crm_product: @omnipotent,
      paid_quantity: 1, gift_quantity: 0
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:product_name_mapping_id], "already has a component for this product"
  end

  test "a mapping can have multiple distinct product components (bundle case)" do
    ProductMappingComponent.create!(
      product_name_mapping: @mapping, crm_product: @omnipotent, paid_quantity: 10, gift_quantity: 2
    )
    ProductMappingComponent.create!(
      product_name_mapping: @mapping, crm_product: @mask, paid_quantity: 0, gift_quantity: 1
    )

    assert_equal 2, @mapping.components.count
  end
end

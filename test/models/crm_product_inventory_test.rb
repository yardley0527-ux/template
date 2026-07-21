# frozen_string_literal: true

require "test_helper"

class CrmProductInventoryTest < ActiveSupport::TestCase
  def build_product(attrs = {})
    CrmProduct.create!({ key: "test_prod_#{SecureRandom.hex(3)}", label: "測試品",
                         status: "confirmed" }.merge(attrs))
  end

  test "defaults to unknown availability_status" do
    assert_equal "unknown", build_product.availability_status
  end

  test "rejects statuses outside AVAILABILITY_STATUSES" do
    product = build_product
    product.availability_status = "sold_out"
    assert_not product.valid?
    assert product.errors[:availability_status].present?
  end

  test "available_for_reminders? truth table" do
    product = build_product
    {
      "in_stock" => true, "low_stock" => true, "preorder" => true,
      "out_of_stock" => false, "discontinued" => false, "unknown" => false
    }.each do |status, expected|
      product.availability_status = status
      assert_equal expected, product.available_for_reminders?, "status=#{status}"
    end
  end

  test "product_trend_detection_enabled? truth table" do
    product = build_product
    {
      "in_stock" => true, "low_stock" => true,
      "preorder" => false, "out_of_stock" => false, "discontinued" => false, "unknown" => false
    }.each do |status, expected|
      product.availability_status = status
      assert_equal expected, product.product_trend_detection_enabled?, "status=#{status}"
    end
  end

  test "setting actual_restock_date does not silently change availability_status" do
    product = build_product(availability_status: "out_of_stock")
    product.update!(actual_restock_date: Date.current)

    assert_equal "out_of_stock", product.reload.availability_status
  end

  test "passed expected_restock_date does not auto-flip status" do
    product = build_product(availability_status: "out_of_stock",
                            expected_restock_date: 10.days.ago.to_date)

    assert_equal "out_of_stock", product.reload.availability_status
    assert_not product.available_for_reminders?
  end

  test "paper_trail records inventory field changes with whodunnit" do
    product = build_product
    user = User.create!(email: "inv@test.com", username: "inv_user", password: "password123")

    PaperTrail.request(whodunnit: user.id.to_s) do
      product.update!(availability_status: "in_stock", actual_restock_date: Date.current)
    end

    version = product.versions.last
    assert version.present?
    assert_equal user.id.to_s, version.whodunnit
    changes = JSON.parse(version.object_changes)
    assert_equal %w[unknown in_stock], changes["availability_status"]
  end

  test "paper_trail ignores non-inventory column changes" do
    product = build_product
    assert_no_difference -> { product.versions.count } do
      product.update!(notes: "只是映射審核備註")
    end
  end
end

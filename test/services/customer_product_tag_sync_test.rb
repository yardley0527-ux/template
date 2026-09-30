# frozen_string_literal: true

require "test_helper"

class CustomerProductTagSyncTest < ActiveSupport::TestCase
  def order(email:, number:, product:, status: "已付款")
    ShoplineOrder.create!(email: email, order_number: number, product_name: product, order_date: 5.days.ago,
                          payment_status: status, total_amount: 1000, checkout_amount: 1000, quantity: 1)
  end

  setup do
    @with_profile = ShoplineCustomer.create!(email: "has@example.com")
    @no_profile   = ShoplineCustomer.create!(email: "new@example.com")
    @unpaid       = ShoplineCustomer.create!(email: "unpaid@example.com")
    @profile = CustomerProfile.create!(shopline_customer_id: @with_profile.id, shengting_product_tags: %w[代謝錠])

    order(email: "has@example.com", number: "A1", product: "PDRN5")
    order(email: "has@example.com", number: "A2", product: "冰晶番茄3")
    order(email: "new@example.com", number: "B1", product: "預購-冰晶蕃茄10送1")
    order(email: "unpaid@example.com", number: "C1", product: "PDRN1", status: "未付款")
  end

  test "adds missing tags without touching manually selected ones, and creates missing profiles" do
    CustomerProductTagSync.call

    assert_equal %w[代謝錠 PDRN 冰晶番茄].sort, @profile.reload.shengting_product_tags.sort
    assert_equal %w[冰晶番茄], CustomerProfile.find_by!(shopline_customer_id: @no_profile.id).shengting_product_tags
  end

  test "ignores unpaid orders" do
    CustomerProductTagSync.call

    assert_nil CustomerProfile.find_by(shopline_customer_id: @unpaid.id)
  end

  test "is idempotent" do
    CustomerProductTagSync.call
    second = CustomerProductTagSync.call

    assert_equal 0, second.values.sum { |r| r[:tags_added] + r[:profiles_created] }
    assert_equal 1, @profile.reload.shengting_product_tags.count("PDRN")
  end
end

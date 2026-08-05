# frozen_string_literal: true

require "test_helper"

class CrmCustomerProductCycleDataQualityReportServiceTest < ActiveSupport::TestCase
  def unique_key
    "dq_#{SecureRandom.hex(4)}"
  end

  def make_order(email:, product_name:, order_date: Date.current - 10, payment_status: "已付款")
    ShoplineOrder.create!(
      order_number: "ORD#{SecureRandom.hex(6)}", email: email, product_name: product_name,
      order_date: order_date, payment_status: payment_status, quantity: 1
    )
  end

  test "flags a product_name that matches no tracked product" do
    order = make_order(email: "a@example.com", product_name: "完全沒對應的商品名稱")

    report = CrmCustomerProductCycleDataQualityReportService.call
    hit = report[:unrecognized_product][:sample].find { |r| r[:order_number] == order.order_number }
    assert hit.present?
  end

  test "excludes refunded/unpaid orders from the report entirely" do
    order = make_order(email: "a@example.com", product_name: "完全沒對應的商品名稱2", payment_status: "已退款")

    report = CrmCustomerProductCycleDataQualityReportService.call
    hit = report[:unrecognized_product][:sample].find { |r| r[:order_number] == order.order_number }
    assert_nil hit
  end

  test "flags ambiguous quantity when neither the product's regex nor the bracket pattern matches" do
    key = unique_key
    CrmProduct.create!(key: key, label: "測試品質商品", status: "confirmed",
                        sql_pattern: "product_name LIKE '%測試品質商品%'", regex_pattern: "測試品質商品(\\d+)")
    order = make_order(email: "a@example.com", product_name: "測試品質商品") # 沒有數字

    report = CrmCustomerProductCycleDataQualityReportService.call
    hit = report[:ambiguous_quantity][:sample].find { |r| r[:order_number] == order.order_number }
    assert hit.present?
    assert_equal key, hit[:product_key]
  end

  test "does not flag ambiguous quantity when the regex explicitly matches" do
    key = unique_key
    CrmProduct.create!(key: key, label: "測試品質商品乙", status: "confirmed",
                        sql_pattern: "product_name LIKE '%測試品質商品乙%'", regex_pattern: "測試品質商品乙(\\d+)")
    order = make_order(email: "a@example.com", product_name: "測試品質商品乙3")

    report = CrmCustomerProductCycleDataQualityReportService.call
    hit = report[:ambiguous_quantity][:sample].find { |r| r[:order_number] == order.order_number }
    assert_nil hit
  end

  test "flags missing_cycle_config when the product has no repurchase cycle config at all" do
    key = unique_key
    CrmProduct.create!(key: key, label: "測試品質商品丙", status: "confirmed",
                        sql_pattern: "product_name LIKE '%測試品質商品丙%'", regex_pattern: "測試品質商品丙(\\d+)")
    order = make_order(email: "a@example.com", product_name: "測試品質商品丙2")

    report = CrmCustomerProductCycleDataQualityReportService.call
    hit = report[:missing_cycle_config][:sample].find { |r| r[:order_number] == order.order_number }
    assert hit.present?
    assert_equal 2, hit[:bottle_count]
  end

  test "does not flag missing_cycle_config once a config row exists for that bucket" do
    key = unique_key
    CrmProduct.create!(key: key, label: "測試品質商品丁", status: "confirmed",
                        sql_pattern: "product_name LIKE '%測試品質商品丁%'", regex_pattern: "測試品質商品丁(\\d+)")
    CrmRepurchaseCycleConfig.create!(product_key: key, bottle_count: 2, median_days: 45, source: "manual")
    order = make_order(email: "a@example.com", product_name: "測試品質商品丁2")

    report = CrmCustomerProductCycleDataQualityReportService.call
    hit = report[:missing_cycle_config][:sample].find { |r| r[:order_number] == order.order_number }
    assert_nil hit
  end
end

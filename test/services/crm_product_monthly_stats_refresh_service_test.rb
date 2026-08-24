# frozen_string_literal: true

require "test_helper"

class CrmProductMonthlyStatsRefreshServiceTest < ActiveSupport::TestCase
  test "natural_revenue does not double-count an order whose product_name drifted across import runs" do
    old_run = ImportRun.create!(kind: "paid_orders_workbook", file_name: "old.csv", file_checksum: SecureRandom.hex(8))
    new_run = ImportRun.create!(kind: "paid_orders_workbook", file_name: "new.csv", file_checksum: SecureRandom.hex(8))
    order_date = Date.new(2026, 1, 15)

    # Both rows match turmeric's LIKE '%薑黃%' pattern — same real order,
    # Shopline's later export just appended a gift suffix to the text.
    ShoplineOrder.create!(order_number: "#CRM1", product_name: "薑黃6", payment_status: "已付款",
                          quantity: 1, checkout_amount: 10500, total_amount: 10500, order_date: order_date,
                          email: "crm1@example.com", source_year: 2026, source_month: 1,
                          import_run_id: old_run.id, source_row_hash: SecureRandom.hex(8))
    ShoplineOrder.create!(order_number: "#CRM1", product_name: "薑黃6送1", payment_status: "已付款",
                          quantity: 1, checkout_amount: 10500, total_amount: 10500, order_date: order_date,
                          email: "crm1@example.com", source_year: 2026, source_month: 1,
                          import_run_id: new_run.id, source_row_hash: SecureRandom.hex(8))

    metrics = CrmProductMonthlyStatsRefreshService.call(product_key: "turmeric", stat_month: order_date)

    assert_equal 10500.to_d, metrics[:natural_revenue]
    assert_equal 1, metrics[:new_buyers_count]
  end
end

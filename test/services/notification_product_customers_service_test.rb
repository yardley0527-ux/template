# frozen_string_literal: true

require "test_helper"

class NotificationProductCustomersServiceTest < ActiveSupport::TestCase
  def build_notification(title:, metadata:)
    Notification.create!(
      notification_key: "test", kind: "opportunity", category: "customer_overdue", severity: "opportunity",
      priority: "P2", title: title, deduplication_key: "test:#{SecureRandom.hex(4)}", status: "detected",
      first_detected_at: Time.current, last_detected_at: Time.current, metadata: metadata
    )
  end

  setup do
    CrmProduct.create!(key: "metabolism", label: "代謝錠", status: "confirmed", availability_status: "in_stock")
  end

  test "merges the same customer across two notifications for the same product into one row with both reasons" do
    ShoplineCustomer.create!(email: "a@example.com", full_name: "阿明")
    # 逾期 10 天：同時落在「1-14天逾期」band 跟「1-60天官網優惠機會」的範圍內，
    # 這是現實中真的會重疊的情境（同一產品的 customer_overdue band + promotion_opportunity）。
    CrmCustomerProductTracking.create!(
      email: "a@example.com", product_key: "metabolism", last_order_date: 30.days.ago.to_date,
      last_order_bottles: 1, expected_return_date: Date.current - 10, suggested_reminder_date: Date.current - 12,
      order_count: 1, total_bottles: 1, refreshed_at: Time.current
    )
    n1 = build_notification(title: "代謝錠逾期未回購（1-14天）", metadata: {
      "query" => { "product_key" => "metabolism", "overdue_days_from" => 1, "overdue_days_to" => 14 }
    })
    n2 = build_notification(title: "代謝錠官網優惠機會", metadata: {
      "query" => { "product_key" => "metabolism", "overdue_days_from" => 1, "overdue_days_to" => 60 }
    })

    rows = NotificationProductCustomersService.call([n1, n2])

    assert_equal 1, rows.size, "the same customer must appear once, not twice"
    assert_includes rows.first[:reasons], "代謝錠逾期未回購（1-14天）"
    assert_includes rows.first[:reasons], "代謝錠官網優惠機會"
  end

  test "returns an empty list for an empty notification list" do
    assert_empty NotificationProductCustomersService.call([])
  end
end

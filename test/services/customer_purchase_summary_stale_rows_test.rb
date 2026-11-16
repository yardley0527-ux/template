# frozen_string_literal: true

require "test_helper"

# 客人補了手機後，舊的 email 列不能留著讓同一人算兩次；人工標記要搬到新列
class CustomerPurchaseSummaryStaleRowsTest < ActiveSupport::TestCase
  test "重算後刪掉舊 email 列並保留 LINE 綁定與追蹤週" do
    ShoplineOrder.create!(order_number: "#x1", order_date: Date.new(2026, 11, 11), email: "Char@Example.com", product_name: "肉鹼1",
                          quantity: 1, checkout_amount: 1_200, total_amount: 1_200, payment_status: "已付款")
    CustomerPurchaseSummaryRefreshService.call
    old = CustomerPurchaseSummary.find_by!(identity_key: "char@example.com")
    old.update_columns(line_bound: true, follow_up_week: Date.new(2026, 11, 9), updated_at: 1.day.ago)

    # 客人後來補了手機
    ShoplineCustomer.create!(email: "char@example.com", full_name: "測試", mobile_phone: "0912345678")
    CustomerPurchaseSummaryRefreshService.call

    rows = CustomerPurchaseSummary.where("LOWER(email) = ?", "char@example.com")
    assert_equal ["0912345678"], rows.pluck(:identity_key)
    assert rows.first.line_bound
    assert_equal Date.new(2026, 11, 9), rows.first.follow_up_week
  end
end

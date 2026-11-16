# frozen_string_literal: true

require "test_helper"

module OrderBrief
  class DailyTotalsTest < ActiveSupport::TestCase
    def order(number, email, date, total:, checkout:)
      ShoplineOrder.create!(order_number: number, email: email, product_name: "PDRN1", quantity: 1, total_amount: total,
                            checkout_amount: checkout, payment_status: "已付款", order_date: Time.utc(date.year, date.month, date.day, 12))
    end

    test "每天合計跟逐天建 Report 一樣：IG 分身以前買過算舊客、整單空白用 checkout、未付款不算" do
      ShoplineCustomer.create!(email: "a@example.com", instagram_account: "same_ig")
      ShoplineCustomer.create!(email: "b@example.com", instagram_account: " Same_IG ")
      ShoplineCustomer.create!(email: "c@example.com", instagram_account: "無")
      ShoplineCustomer.create!(email: "d@example.com", instagram_account: "無")

      order("#A0", "a@example.com", Date.new(2026, 9, 1), total: 1000, checkout: 1000)
      order("#B1", "B@example.com ", Date.new(2026, 10, 1), total: 5000, checkout: 5000)   # 分身以前買過→舊客
      order("#C1", "c@example.com", Date.new(2026, 10, 1), total: nil, checkout: 700)
      order("#C1", "c@example.com", Date.new(2026, 10, 1), total: nil, checkout: 300)      # 整單空白→checkout 加總
      order("#C2", "c@example.com", Date.new(2026, 10, 2), total: 2000, checkout: 2000)    # 隔天變舊客
      order("#D1", "d@example.com", Date.new(2026, 9, 1), total: 9000, checkout: 9000)     # 「無」不是同一人
      ShoplineOrder.create!(order_number: "#X", email: "x@example.com", total_amount: 9999, payment_status: "未付款",
                            order_date: Time.utc(2026, 10, 1, 12))

      range = Date.new(2026, 10, 1)..Date.new(2026, 10, 3)
      totals = DailyTotals.new(range)
      range.each do |d|
        rows = Report.new(d).rows
        t = totals[d]
        assert_equal [rows.sum(&:amount), rows.sum { |r| r.orders.size }, rows.select(&:new_customer?).sum(&:amount)],
                     [t.amount, t.orders, t.new_amount], d.to_s
      end
      assert_equal [6000.0, 2, 1000.0], [totals[range.first].amount, totals[range.first].orders, totals[range.first].new_amount]
      assert_equal 2000.0, totals[Date.new(2026, 10, 2)].old_amount
      assert totals[Date.new(2026, 10, 3)].empty?
    end
  end
end

# frozen_string_literal: true

require "test_helper"

class Manychat::LeadReportTest < ActiveSupport::TestCase
  NOW = Time.zone.local(2026, 10, 27, 18, 0)

  def lead(sid, at, source:, customer: nil)
    sub = ManychatSubscriber.create!(account_key: "chloe.chao", subscriber_id: sid, name: "客#{sid}",
                                     ig_username: customer&.instagram_account || "nobody#{sid}")
    sub.manychat_interactions.create!(interacted_at: at, source: source)
    sub
  end

  def order(customer, number, at, amount)
    ShoplineOrder.create!(shopline_customer_id: customer.id, order_number: number, order_date: at,
                          payment_status: "已付款", total_amount: amount, product_name: "PDRN1", quantity: 1)
  end

  test "依有沒有買、多久前互動分群，並算各來源 7 天內下單" do
    buyer = ShoplineCustomer.create!(full_name: "新客", instagram_account: "buyer")
    old = ShoplineCustomer.create!(full_name: "舊客", instagram_account: "old")
    late = ShoplineCustomer.create!(full_name: "晚買", instagram_account: "late")

    lead(1, NOW - 3.days, source: "PDRN post1", customer: buyer)
    order(buyer, "A1", NOW - 2.days, 2650)
    lead(2, NOW - 2.days, source: "PDRN post1", customer: old)
    order(old, "B0", NOW - 60.days, 5000)
    lead(3, NOW - 2.hours, source: "b群 story2")
    lead(4, NOW - 3.days - 1.hour, source: "")
    lead(5, NOW - 12.days, source: "PDRN post1", customer: late)
    order(late, "C1", NOW - 1.day, 9000) # 互動 11 天後才買：算新客，但不算 7 天內下單

    report = Manychat::LeadReport.new(account: "chloe.chao", from: (NOW - 13.days).to_date, to: NOW.to_date, now: NOW)
    status = report.leads.to_h { |l| [l.subscriber.subscriber_id, l.status] }
    assert_equal({ 1 => "new_buyer", 2 => "existing", 3 => "open", 4 => "closed", 5 => "new_buyer" }, status)
    assert_equal 9000, report.leads.find { |l| l.subscriber.subscriber_id == 5 }.amount_after

    pdrn = report.funnel.find { |r| r[:source] == "PDRN post1" }
    assert_equal({ source: "PDRN post1", people: 3, matched: 3, existing: 1, converted: 1, revenue: 2650.0 }, pdrn)
    assert report.funnel.any? { |r| r[:source] == Manychat::LeadReport::NO_SOURCE }

    days = report.daily.to_h { |r| [r[:date], r.slice(:people, :converted, :revenue)] }
    assert_equal({ people: 2, converted: 1, revenue: 2650.0 }, days[(NOW - 3.days).to_date])
    assert_equal (NOW - 2.hours).to_date, report.daily.first[:date]
    assert_equal [3, 2, 1, 4, 5], report.leads.map { |l| l.subscriber.subscriber_id }
  end

  test "只看選的來源" do
    lead(1, NOW - 1.day, source: "PDRN post1")
    lead(2, NOW - 1.day, source: "b群 story2")
    report = Manychat::LeadReport.new(account: "chloe.chao", from: NOW.to_date - 7, to: NOW.to_date, source: "b群 story2", now: NOW)
    assert_equal [2], report.leads.map { |l| l.subscriber.subscriber_id }
  end
end

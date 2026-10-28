# frozen_string_literal: true

require "test_helper"

class Marketing::SourcePerformanceTest < ActiveSupport::TestCase
  NOW = Time.zone.local(2026, 10, 29, 12, 0)

  def verified(sid, ig)
    c = ShoplineCustomer.create!(full_name: ig, instagram_account: ig)
    s = ManychatSubscriber.create!(account_key: "chloechao0527", subscriber_id: sid, ig_username: ig)
    s.confirm!(c.id, user: nil)
    [s, c]
  end

  def order(c, at, number, amount)
    ShoplineOrder.create!(shopline_customer_id: c.id, order_number: number, order_date: at, payment_status: "已付款",
                          total_amount: amount, product_name: "x", quantity: 1)
  end

  test "未滿觀察期的人不進分母；同一人同一訂單跨來源，合計去重；樣本不足標示" do
    order(ShoplineCustomer.create!(full_name: "資料到 10/27"), Time.zone.local(2026, 10, 27, 9), "LAST", 1)
    s1, c1 = verified(1, "aa")
    s1.manychat_interactions.create!(interacted_at: Time.zone.local(2026, 10, 15, 10), source: "A")
    s1.manychat_interactions.create!(interacted_at: Time.zone.local(2026, 10, 16, 10), source: "B")
    order(c1, Time.zone.local(2026, 10, 17, 10), "O1", 2000)
    s2, = verified(2, "bb")
    s2.manychat_interactions.create!(interacted_at: Time.zone.local(2026, 10, 25, 10), source: "A") # 10/25 + 7 > 10/27
    unmatched = ManychatSubscriber.create!(account_key: "chloechao0527", subscriber_id: 3, ig_username: "cc")
    unmatched.manychat_interactions.create!(interacted_at: Time.zone.local(2026, 10, 15, 10), source: "A")

    perf = Marketing::SourcePerformance.new(from: Date.new(2026, 10, 1), to: Date.new(2026, 10, 29), now: NOW)
    a = perf.rows.find { |r| r.source == "A" }
    assert_equal [3, 2, 1, 1, 1, 2000.0], [a.people, a.verified, a.matured, a.immature, a.converted, a.linked_amount]
    assert_not a.sample_ok?
    assert_nil perf.rows.find { |r| r.source == "B" }.then { |b| b.sample_ok? ? b.rate : nil }

    total = perf.total
    assert_equal [3, 1, 2000.0], [total.people, total.converted, total.linked_amount] # 不是 A+B 相加
  end
end

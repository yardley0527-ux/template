# frozen_string_literal: true

require "test_helper"

class Marketing::SegmentsTest < ActiveSupport::TestCase
  NOW = Time.zone.local(2026, 10, 29, 12, 0)

  setup do
    CrmProduct.create!(key: "pdrn", label: "PDRN", status: "confirmed")
    CrmProduct.create!(key: "fish_oil", label: "魚油", status: "confirmed")
    @segments = Marketing::Segments.new(now: NOW)
  end

  def subscriber(sid, customer: nil, ig: nil)
    s = ManychatSubscriber.create!(account_key: "chloechao0527", subscriber_id: sid, ig_username: customer&.instagram_account || ig || "u#{sid}")
    s.confirm!(customer.id, user: nil) if customer
    s
  end

  def interact(sub, at, source)
    sub.manychat_interactions.create!(interacted_at: at, source: source)
  end

  def order(customer, at, number: SecureRandom.hex(3), amount: 1000)
    ShoplineOrder.create!(shopline_customer_id: customer.id, order_number: number, order_date: at, payment_status: "已付款",
                          total_amount: amount, product_name: "x", quantity: 1)
  end

  test "未比對、候選的人購買狀態是未知，不會被當成沒買過" do
    bought = ShoplineCustomer.create!(full_name: "買過", instagram_account: "bought", email: "b@x.com")
    never = ShoplineCustomer.create!(full_name: "沒買", instagram_account: "never", email: "n@x.com")
    ShoplineCustomer.create!(full_name: "候選", instagram_account: "cand")
    order(bought, NOW - 30.days)
    [subscriber(1, customer: bought), subscriber(2, customer: never), subscriber(3, ig: "cand"), subscriber(4)].each do |s|
      interact(s, NOW - 1.day, "PDRN post1")
    end

    r = @segments.build("recent_interactors", "days" => 7)
    assert_equal({ "verified_purchased" => 1, "verified_no_purchase" => 1, "candidate" => 1, "unmatched" => 1 }, r.breakdown["purchase_status"])
    assert_equal [2], @segments.build("never_purchased", "days" => 7).members.map { |m| ManychatSubscriber.find(m["manychat_subscriber_id"]).subscriber_id }
    assert(r.members.all? { |m| m["contact"] == "待確認" })
    cand = r.members.find { |m| m["match_status"] == "candidate" }
    assert_equal ["candidate", 0], [cand["purchase_status"], cand["candidate_orders"]] # 有提示，但仍是未知
  end

  test "互動後未下單 ≠ 從未購買：之前買過、互動後沒買的人只在前者" do
    c = ShoplineCustomer.create!(full_name: "舊客", instagram_account: "old")
    order(c, NOW - 60.days)
    interact(subscriber(1, customer: c), NOW - 2.days, "")
    assert_equal 1, @segments.build("interacted_not_ordered", "days" => 7).count
    assert_equal 0, @segments.build("never_purchased", "days" => 7).count

    order(c, NOW - 1.day)
    assert_equal 0, @segments.build("interacted_not_ordered", "days" => 7).count
  end

  test "黑名單／不追蹤的人排除在經營客群外" do
    c = ShoplineCustomer.create!(full_name: "不追蹤", instagram_account: "skip")
    CustomerProfile.create!(shopline_customer: c, skip_follow_up: true)
    interact(subscriber(1, customer: c), NOW - 1.day, "")
    assert_equal 0, @segments.build("never_purchased", "days" => 7).count
    assert_equal "CRM 標記不追蹤", @segments.build("recent_interactors", "days" => 7).members.first["excluded_reason"]
  end

  test "產品互動只看人工設定的來源對應，不靠名稱猜；買過／沒買過此產品／未知分開" do
    ManychatSource.create!(key: "chloe-pdrn-post1", name: "PDRN 貼文 1", account_key: "chloechao0527", raw_names: ["PDRN post1"], product_keys: ["pdrn"])
    buyer = ShoplineCustomer.create!(full_name: "買過 PDRN", instagram_account: "pb", email: "pb@x.com")
    CrmCustomerProductCycle.create!(identity_key: "pb", email: "pb@x.com", product_key: "pdrn", cycle_started_at: Date.new(2026, 9, 1),
                                    bottle_count: 1, estimated_usage_days: 30, estimated_finish_date: Date.new(2026, 10, 1),
                                    suggested_contact_date: Date.new(2026, 9, 24), match_status: "not_yet_repurchased", refreshed_at: NOW)
    other = ShoplineCustomer.create!(full_name: "沒買 PDRN", instagram_account: "po", email: "po@x.com")
    interact(subscriber(1, customer: buyer), NOW - 1.day, "PDRN post1")
    interact(subscriber(2, customer: other), NOW - 1.day, "PDRN post1")
    interact(subscriber(3), NOW - 1.day, "PDRN post1")
    interact(subscriber(4), NOW - 1.day, "PDRN post2") # 沒設定對應

    r = @segments.build("product_source_interest", "product_key" => "pdrn", "days" => 7)
    assert_equal({ "bought" => 1, "not_bought" => 1, "unknown" => 1 }, r.breakdown["product_purchase"])
    assert_equal 0, @segments.build("product_explicit_request", "product_key" => "pdrn", "days" => 7).count
  end

  test "回購機會沿用 CRM 週期：不受 ManyChat 比對影響，標示週期依據與是否有 ManyChat 互動" do
    CrmRepurchaseCycleConfig.create!(product_key: "fish_oil", bottle_count: 1, median_days: 45, sample_size: 173, source: "historical_median")
    CrmRepurchaseCycleConfig.create!(product_key: "pdrn", bottle_count: 1, median_days: 30, sample_size: 0, source: "legacy_journey_products")
    a = ShoplineCustomer.create!(full_name: "甲", email: "a@x.com", instagram_account: "aa")
    ShoplineCustomer.create!(full_name: "乙", email: "b@x.com")
    { "a@x.com" => "fish_oil", "b@x.com" => "pdrn" }.each do |email, product|
      CrmCustomerProductCycle.create!(identity_key: email, email: email, product_key: product, cycle_started_at: Date.new(2026, 9, 20),
                                      bottle_count: 1, estimated_usage_days: 40, estimated_finish_date: Date.new(2026, 10, 30),
                                      suggested_contact_date: Date.new(2026, 10, 31), match_status: "not_yet_repurchased", refreshed_at: NOW)
    end
    interact(subscriber(1, customer: a), NOW - 3.days, "")

    all = @segments.build("repurchase_due", "ahead" => 7)
    assert_equal 2, all.count
    assert_equal({ "historical" => 1, "assumption" => 1 }, all.breakdown["cycle_basis"])
    assert_equal 1, @segments.build("repurchase_due", "ahead" => 7, "manychat_only" => true).count
  end

  test "參數白名單：不存在的產品、客群拒絕，非法天數改用預設" do
    assert_raises(ArgumentError) { @segments.build("product_source_interest", "product_key" => "drop table") }
    assert_raises(KeyError, ArgumentError) { @segments.build("anything", {}) }
    assert_equal 14, Marketing::Segments.normalize_params("recent_interactors", "days" => "999", "sql" => "x")["days"]
  end
end

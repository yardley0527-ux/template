# frozen_string_literal: true

require "test_helper"

class CrmCustomerProductCycleBuilderServiceTest < ActiveSupport::TestCase
  def unique_key
    "builder_#{SecureRandom.hex(4)}"
  end

  def make_product(key, label, medians: { 1 => 30 })
    product = CrmProduct.create!(key: key, label: label, status: "confirmed",
                                  sql_pattern: "product_name LIKE '%#{label}%'", regex_pattern: "#{label}(\\d+)")
    medians.each { |bottles, days| CrmRepurchaseCycleConfig.create!(product_key: key, bottle_count: bottles, median_days: days, source: "manual") }
    product
  end

  def make_order(email:, product_name:, order_date:, payment_status: "已付款", order_number: nil)
    ShoplineOrder.create!(
      order_number: order_number || "ORD#{SecureRandom.hex(6)}", email: email, product_name: product_name,
      order_date: order_date, payment_status: payment_status, quantity: 1
    )
  end

  test "excludes refunded, unpaid, and blank-field orders from cycle creation" do
    key = unique_key
    make_product(key, "測試甲")
    email = "buyer_#{SecureRandom.hex(4)}@example.com"

    make_order(email: email, product_name: "測試甲1", order_date: Date.new(2026, 1, 1))
    make_order(email: email, product_name: "測試甲1", order_date: Date.new(2026, 2, 1), payment_status: "未付款")
    make_order(email: email, product_name: "測試甲1", order_date: Date.new(2026, 2, 15), payment_status: "已退款")

    CrmCustomerProductCycleBuilderService.call(product_key: key)

    cycles = CrmCustomerProductCycle.where(product_key: key)
    assert_equal 1, cycles.count
    assert_equal Date.new(2026, 1, 1), cycles.first.cycle_started_at
  end

  test "merges identity across emails sharing the same mobile_phone" do
    key = unique_key
    make_product(key, "測試乙")
    email_a = "a_#{SecureRandom.hex(4)}@example.com"
    email_b = "b_#{SecureRandom.hex(4)}@example.com"
    phone   = format("09%08d", rand(100_000_000))
    ShoplineCustomer.create!(email: email_a, mobile_phone: phone, full_name: "x")
    ShoplineCustomer.create!(email: email_b, mobile_phone: phone, full_name: "y")

    make_order(email: email_a, product_name: "測試乙1", order_date: Date.new(2026, 1, 1))
    make_order(email: email_b, product_name: "測試乙1", order_date: Date.new(2026, 6, 1)) # 換 email 買的下一筆

    CrmCustomerProductCycleBuilderService.call(product_key: key)

    cycles = CrmCustomerProductCycle.where(product_key: key).order(:cycle_started_at)
    assert_equal 2, cycles.count
    assert_equal cycles.first.identity_key, cycles.second.identity_key
    assert_equal "same_product_repurchase", cycles.first.match_status
  end

  test "skips a purchase event when there is no repurchase cycle config for that bottle count" do
    key = unique_key
    CrmProduct.create!(key: key, label: "測試丙", status: "confirmed", sql_pattern: "product_name LIKE '%測試丙%'")
    make_order(email: "a@example.com", product_name: "測試丙1", order_date: Date.new(2026, 1, 1))

    result = CrmCustomerProductCycleBuilderService.call(product_key: key)
    assert_equal 0, result
    assert_equal 0, CrmCustomerProductCycle.where(product_key: key).count
  end

  test "classifies same_product_repurchase when the next order is the same product, outside the addon window" do
    key = unique_key
    make_product(key, "測試丁", medians: { 1 => 60 })
    email = "a_#{SecureRandom.hex(4)}@example.com"

    make_order(email: email, product_name: "測試丁1", order_date: Date.new(2026, 1, 1))
    make_order(email: email, product_name: "測試丁1", order_date: Date.new(2026, 3, 1)) # 59 天後，遠超加購窗

    CrmCustomerProductCycleBuilderService.call(product_key: key)

    cycle = CrmCustomerProductCycle.where(product_key: key, cycle_started_at: Date.new(2026, 1, 1)).first
    assert_equal "same_product_repurchase", cycle.match_status
    assert_equal Date.new(2026, 3, 1), cycle.matched_next_order_date
  end

  test "classifies same_product_addon when the next same-product order lands inside the addon window" do
    key = unique_key
    make_product(key, "測試戊", medians: { 1 => 60 }) # addon window = max(60*0.3, 3) = 18 天
    email = "a_#{SecureRandom.hex(4)}@example.com"

    make_order(email: email, product_name: "測試戊1", order_date: Date.new(2026, 1, 1))
    make_order(email: email, product_name: "測試戊1", order_date: Date.new(2026, 1, 10)) # 9 天後，落在加購窗內

    CrmCustomerProductCycleBuilderService.call(product_key: key)

    cycle = CrmCustomerProductCycle.where(product_key: key, cycle_started_at: Date.new(2026, 1, 1)).first
    assert_equal "same_product_addon", cycle.match_status
  end

  test "classifies cross_product_purchase when the next order is a different tracked product" do
    key_a = unique_key
    key_b = unique_key
    make_product(key_a, "測試己甲", medians: { 1 => 60 })
    make_product(key_b, "測試己乙", medians: { 1 => 60 })
    email = "a_#{SecureRandom.hex(4)}@example.com"

    make_order(email: email, product_name: "測試己甲1", order_date: Date.new(2026, 1, 1))
    make_order(email: email, product_name: "測試己乙1", order_date: Date.new(2026, 1, 20))

    CrmCustomerProductCycleBuilderService.call(product_key: key_a)

    cycle = CrmCustomerProductCycle.where(product_key: key_a, cycle_started_at: Date.new(2026, 1, 1)).first
    assert_equal "cross_product_purchase", cycle.match_status
    assert_equal key_b, cycle.matched_next_product_key
  end

  test "classifies not_yet_repurchased when there is no subsequent order at all" do
    key = unique_key
    make_product(key, "測試庚", medians: { 1 => 60 })
    make_order(email: "a_#{SecureRandom.hex(4)}@example.com", product_name: "測試庚1", order_date: Date.new(2026, 1, 1))

    CrmCustomerProductCycleBuilderService.call(product_key: key)

    cycle = CrmCustomerProductCycle.where(product_key: key).first
    assert_equal "not_yet_repurchased", cycle.match_status
    assert_nil cycle.matched_at
  end

  test "idempotent: rerunning does not create duplicate rows or change matched_at for an unchanged match" do
    key = unique_key
    make_product(key, "測試辛", medians: { 1 => 60 })
    email = "a_#{SecureRandom.hex(4)}@example.com"
    make_order(email: email, product_name: "測試辛1", order_date: Date.new(2026, 1, 1))
    make_order(email: email, product_name: "測試辛1", order_date: Date.new(2026, 3, 1))

    CrmCustomerProductCycleBuilderService.call(product_key: key)
    cycle = CrmCustomerProductCycle.where(product_key: key, cycle_started_at: Date.new(2026, 1, 1)).first
    first_matched_at = cycle.matched_at
    first_count = CrmCustomerProductCycle.where(product_key: key).count

    travel 1.hour do
      CrmCustomerProductCycleBuilderService.call(product_key: key)
    end

    cycle.reload
    assert_equal first_count, CrmCustomerProductCycle.where(product_key: key).count
    assert_equal first_matched_at, cycle.matched_at
  end

  test "manual override fields survive a rebuild" do
    key = unique_key
    make_product(key, "測試壬", medians: { 1 => 60 })
    make_order(email: "a_#{SecureRandom.hex(4)}@example.com", product_name: "測試壬1", order_date: Date.new(2026, 1, 1))

    CrmCustomerProductCycleBuilderService.call(product_key: key)
    cycle = CrmCustomerProductCycle.where(product_key: key).first
    CrmCustomerProductCycleOverrideService.call(cycle: cycle, remaining_days: 5, source: "qa")

    CrmCustomerProductCycleBuilderService.call(product_key: key)
    cycle.reload
    assert_equal 5, cycle.manual_override_remaining_days
    assert_equal "qa", cycle.manual_override_source
  end

  test "sums bottle_count across multiple same-day line items of the same product" do
    key = unique_key
    make_product(key, "測試癸", medians: { 3 => 60 })
    email = "a_#{SecureRandom.hex(4)}@example.com"
    order_number = "ORDMULTI#{SecureRandom.hex(4)}"
    make_order(email: email, product_name: "測試癸1", order_date: Date.new(2026, 1, 1), order_number: order_number)
    make_order(email: email, product_name: "測試癸2", order_date: Date.new(2026, 1, 1), order_number: "#{order_number}B")

    CrmCustomerProductCycleBuilderService.call(product_key: key)

    cycle = CrmCustomerProductCycle.where(product_key: key).first
    assert_equal 3, cycle.bottle_count
  end

  test "bounded query count for a batch of purchase events (no N+1 per customer)" do
    key = unique_key
    make_product(key, "測試子", medians: { 1 => 60 })

    20.times do |i|
      email = "batch_#{i}_#{SecureRandom.hex(4)}@example.com"
      make_order(email: email, product_name: "測試子1", order_date: Date.new(2026, 1, 1))
    end

    query_count = 0
    counter = ->(*, payload) { query_count += 1 if payload[:sql] =~ /\A(SELECT|INSERT)/i }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      CrmCustomerProductCycleBuilderService.call(product_key: key)
    end

    # 20 位顧客應該只需要固定幾條 SQL（events 查詢、subsequent orders 查詢、一次 upsert INSERT），
    # 不隨顧客數線性成長。抓一個寬鬆但足以攔截 N+1 的上限。
    assert query_count < 10, "expected O(1) queries, got #{query_count}"
  end
end

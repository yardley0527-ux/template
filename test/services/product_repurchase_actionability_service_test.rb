# frozen_string_literal: true

require "test_helper"

class ProductRepurchaseActionabilityServiceTest < ActiveSupport::TestCase
  def make_cycle(email:, product_key:, overdue_days:, follow_up_status: nil, last_contacted_at: nil, ref: Date.current)
    finish = ref - overdue_days
    CrmCustomerProductCycle.create!(
      identity_key: email, email: email, product_key: product_key,
      cycle_started_at: finish - 30, bottle_count: 1, estimated_usage_days: 30,
      estimated_finish_date: finish, suggested_contact_date: finish,
      match_status: "not_yet_repurchased", refreshed_at: Time.current,
      follow_up_status: follow_up_status, last_contacted_at: last_contacted_at
    )
  end

  def make_summary(email:, purchase_count: 1, last_order_date: Date.current - 10, line_bound: true, mobile_phone: "0912345678")
    CustomerPurchaseSummary.create!(identity_key: "id_#{email}", email: email, first_date: last_order_date - 400,
                                     purchase_count: purchase_count, silent_only: false, silent_days_threshold: 45,
                                     last_order_date: last_order_date, line_bound: line_bound, mobile_phone: mobile_phone)
  end

  # 產生一筆「已回購」的歷史週期（match_status 不是 not_yet_repurchased），
  # 用來墊高某個 identity_key 對這個產品的「過去回購次數」，供 A/B/C 分層
  # 測試使用——cycle_started_at 要跟其餘週期錯開，否則會撞到
  # (identity_key, product_key, cycle_started_at) 的唯一性驗證。
  def make_matched_cycle(email:, product_key:, started_days_ago:, ref: Date.current)
    started = ref - started_days_ago
    CrmCustomerProductCycle.create!(
      identity_key: email, email: email, product_key: product_key,
      cycle_started_at: started, bottle_count: 1, estimated_usage_days: 30,
      estimated_finish_date: started + 30, suggested_contact_date: started + 30,
      match_status: "same_product_repurchase", refreshed_at: Time.current,
      matched_next_order_date: started + 35, matched_next_order_number: "ORD#{SecureRandom.hex(4)}",
      matched_next_product_key: product_key
    )
  end

  test "buckets overdue cycles into the correct age range" do
    key = "pras_#{SecureRandom.hex(4)}"
    make_cycle(email: "a@example.com", product_key: key, overdue_days: 15)
    make_summary(email: "a@example.com")
    make_cycle(email: "b@example.com", product_key: key, overdue_days: 200)
    make_summary(email: "b@example.com")

    result = ProductRepurchaseActionabilityService.call(product_key: key, reference_date: Date.current, availability_status: "in_stock")

    assert_equal 1, result["age_buckets"]["1-30"]
    assert_equal 1, result["age_buckets"]["181-365"]
    assert_equal 2, result["total_overdue"]
  end

  test "excludes an out-of-stock product from the actionable count even if otherwise eligible" do
    key = "pras_#{SecureRandom.hex(4)}"
    make_cycle(email: "a@example.com", product_key: key, overdue_days: 15)
    make_summary(email: "a@example.com")

    in_stock = ProductRepurchaseActionabilityService.call(product_key: key, reference_date: Date.current, availability_status: "in_stock")
    out_of_stock = ProductRepurchaseActionabilityService.call(product_key: key, reference_date: Date.current, availability_status: "out_of_stock")

    assert_equal 1, in_stock["actionable_count"]
    assert_equal 0, out_of_stock["actionable_count"]
  end

  test "a cycle with an active follow-up status is not counted as overdue at all (matches the Repurchase Dashboard's own definition)" do
    key = "pras_#{SecureRandom.hex(4)}"
    make_cycle(email: "a@example.com", product_key: key, overdue_days: 15, follow_up_status: "waiting_reply")
    make_summary(email: "a@example.com")

    result = ProductRepurchaseActionabilityService.call(product_key: key, reference_date: Date.current, availability_status: "in_stock")

    # follow_up_status 一旦有值就不算在「逾期未回購」裡（改算在 waiting_reply
    # 底下），所以這裡的 already_has_task_count 結構上恆為0——不是漏算，是
    # 跟 CrmRepurchaseDashboardQuery 同一份既有定義。
    assert_equal 0, result["total_overdue"]
    assert_equal 0, result["already_has_task_count"]
    assert_equal 0, result["actionable_count"]
  end

  test "excludes a customer contacted within the last 30 days" do
    key = "pras_#{SecureRandom.hex(4)}"
    make_cycle(email: "a@example.com", product_key: key, overdue_days: 15, last_contacted_at: 5.days.ago)
    make_summary(email: "a@example.com")

    result = ProductRepurchaseActionabilityService.call(product_key: key, reference_date: Date.current, availability_status: "in_stock")

    assert_equal 1, result["contacted_last_30d_count"]
    assert_equal 0, result["actionable_count"]
  end

  test "excludes overdue beyond the max actionable window" do
    key = "pras_#{SecureRandom.hex(4)}"
    make_cycle(email: "a@example.com", product_key: key, overdue_days: 400)
    make_summary(email: "a@example.com")

    result = ProductRepurchaseActionabilityService.call(product_key: key, reference_date: Date.current, availability_status: "in_stock")

    assert_equal 0, result["actionable_count"]
  end

  test "excludes a customer with no line binding and no phone as not reachable" do
    key = "pras_#{SecureRandom.hex(4)}"
    make_cycle(email: "a@example.com", product_key: key, overdue_days: 15)
    make_summary(email: "a@example.com", line_bound: false, mobile_phone: nil)

    result = ProductRepurchaseActionabilityService.call(product_key: key, reference_date: Date.current, availability_status: "in_stock")

    assert_equal 0, result["reachable_count"]
    assert_equal 0, result["actionable_count"]
  end

  # ── A/B/C/沉睡分層 ───────────────────────────────────────────────
  test "classifies a recently-overdue, repeat repurchaser as tier A" do
    key = "pras_#{SecureRandom.hex(4)}"
    make_matched_cycle(email: "a_tier@example.com", product_key: key, started_days_ago: 400)
    make_matched_cycle(email: "a_tier@example.com", product_key: key, started_days_ago: 200)
    make_cycle(email: "a_tier@example.com", product_key: key, overdue_days: 15) # cycle_started_at 是最近的，才是 active
    make_summary(email: "a_tier@example.com")

    result = ProductRepurchaseActionabilityService.call(product_key: key, reference_date: Date.current, availability_status: "in_stock")
    assert_equal 1, result.dig("tiers", "a_tier_count")
  end

  test "an overdue-0-30 customer with fewer than 2 past repurchases falls into tier B (not unclassified)" do
    key = "pras_#{SecureRandom.hex(4)}"
    make_matched_cycle(email: "one_time@example.com", product_key: key, started_days_ago: 200)
    make_cycle(email: "one_time@example.com", product_key: key, overdue_days: 15)
    make_summary(email: "one_time@example.com")

    result = ProductRepurchaseActionabilityService.call(product_key: key, reference_date: Date.current, availability_status: "in_stock")
    assert_equal 0, result.dig("tiers", "a_tier_count")
    assert_equal 1, result.dig("tiers", "b_tier_count")
    assert_equal 0, result.dig("tiers", "unclassified_count")
  end

  test "an overdue-31-90 customer who never repurchased falls into tier C (not unclassified)" do
    key = "pras_#{SecureRandom.hex(4)}"
    make_cycle(email: "never_repurchased@example.com", product_key: key, overdue_days: 60)
    make_summary(email: "never_repurchased@example.com")

    result = ProductRepurchaseActionabilityService.call(product_key: key, reference_date: Date.current, availability_status: "in_stock")
    assert_equal 0, result.dig("tiers", "b_tier_count")
    assert_equal 1, result.dig("tiers", "c_tier_count")
    assert_equal 0, result.dig("tiers", "unclassified_count")
  end

  # ── 邊界測試：classify_tier 在每個分層邊界 × 回購次數0/1/2 ─────────
  # 規則：A=(0-30,>=2) / B=(0-30,<2)或(31-90,>=1) / C=(31-90,==0)或(91-180,任意) / 沉睡=(>180)
  # 直接測 classify_tier（不透過整條 overdue scope 查詢）：overdue_days=0
  # 這個值在規格上是A/B級的合法輸入邊界，但目前 CrmCustomerProductCycle
  # 「overdue」scope 定義是 remaining<0（即 overdue_days>=1，當天到期算
  # due_today不算overdue）——那是既有、跟本次分層需求無關的定義，不在這次
  # 修改範圍內，所以這裡直接測分類函式本身，不依賴能否組出 overdue_days=0
  # 的真實overdue列。
  test "boundary matrix: classify_tier covers every overdue-day × repurchase-count combination exactly once" do
    service = ProductRepurchaseActionabilityService.new("any_key", Date.current, "in_stock")
    expectations = {
      [0, 0]   => :b,
      [0, 1]   => :b,
      [0, 2]   => :a,
      [30, 0]  => :b,
      [30, 1]  => :b,
      [30, 2]  => :a,
      [31, 0]  => :c,
      [31, 1]  => :b,
      [31, 2]  => :b,
      [90, 0]  => :c,
      [90, 1]  => :b,
      [90, 2]  => :b,
      [91, 0]  => :c,
      [91, 1]  => :c,
      [91, 2]  => :c,
      [180, 0] => :c,
      [180, 1] => :c,
      [180, 2] => :c,
      [181, 0] => :dormant,
      [181, 1] => :dormant,
      [181, 2] => :dormant
    }

    expectations.each do |(overdue_days, repurchase_count), expected_tier|
      actual = service.send(:classify_tier, overdue_days, repurchase_count)
      assert_equal expected_tier, actual,
                   "overdue_days=#{overdue_days} repurchase_count=#{repurchase_count} expected #{expected_tier}, got #{actual.inspect}"
    end
  end

  test "boundary matrix via the real overdue scope (days 1..181) also lands in exactly one tier, unclassified stays 0" do
    expectations = {
      [1, 0]   => :b_tier_count,
      [1, 2]   => :a_tier_count,
      [30, 1]  => :b_tier_count,
      [31, 0]  => :c_tier_count,
      [31, 1]  => :b_tier_count,
      [90, 1]  => :b_tier_count,
      [91, 0]  => :c_tier_count,
      [180, 2] => :c_tier_count,
      [181, 0] => :dormant_tier_count
    }

    expectations.each_with_index do |((overdue_days, repurchase_count), expected_tier_key), idx|
      key = "pras_#{SecureRandom.hex(4)}"
      email = "boundary_#{idx}@example.com"
      repurchase_count.times { |i| make_matched_cycle(email: email, product_key: key, started_days_ago: 300 + i * 10) }
      make_cycle(email: email, product_key: key, overdue_days: overdue_days)
      make_summary(email: email)

      result = ProductRepurchaseActionabilityService.call(product_key: key, reference_date: Date.current, availability_status: "in_stock")
      tiers = result["tiers"]

      landed_tier = %i[a_tier_count b_tier_count c_tier_count dormant_tier_count unclassified_count].find { |k| tiers[k.to_s] == 1 }
      assert_equal expected_tier_key, landed_tier,
                   "overdue_days=#{overdue_days} repurchase_count=#{repurchase_count} expected #{expected_tier_key}, tiers=#{tiers.inspect}"
      assert_equal 0, tiers["unclassified_count"], "overdue_days=#{overdue_days} repurchase_count=#{repurchase_count} should not be unclassified"

      # 每人只落入一層：所有分層計數加總必須等於這筆資料的 total_overdue(=1)
      assert_equal 1, %w[a_tier_count b_tier_count c_tier_count dormant_tier_count unclassified_count].sum { |k| tiers[k] }
    end
  end

  test "unclassified stays 0 for a full week of normal fixture-shaped data across every tier" do
    key = "pras_#{SecureRandom.hex(4)}"
    [[5, 3], [20, 0], [45, 1], [80, 0], [120, 5], [250, 0]].each_with_index do |(overdue_days, repurchase_count), idx|
      email = "normal_#{idx}@example.com"
      repurchase_count.times { |i| make_matched_cycle(email: email, product_key: key, started_days_ago: 300 + i * 5) }
      make_cycle(email: email, product_key: key, overdue_days: overdue_days)
      make_summary(email: email)
    end

    result = ProductRepurchaseActionabilityService.call(product_key: key, reference_date: Date.current, availability_status: "in_stock")
    tiers = result["tiers"]

    assert_equal 0, tiers["unclassified_count"]
    assert_equal result["total_overdue"],
                 %w[a_tier_count b_tier_count c_tier_count dormant_tier_count unclassified_count].sum { |k| tiers[k] }
  end

  test "unclassified is used for a malformed/out-of-range overdue value, not silently dropped" do
    service = ProductRepurchaseActionabilityService.new("any_key", Date.current, "in_stock")

    assert_equal :unclassified, service.send(:classify_tier, nil, 2)
    assert_equal :unclassified, service.send(:classify_tier, -5, 2)
    assert_equal :unclassified, service.send(:classify_tier, 15, nil)
    assert_equal :unclassified, service.send(:classify_tier, 15, -1)
    assert_equal :unclassified, service.send(:classify_tier, "not_a_number", 2)
  end

  test "classifies an overdue-31-90 customer who has repurchased at least once as tier B" do
    key = "pras_#{SecureRandom.hex(4)}"
    make_matched_cycle(email: "b_tier@example.com", product_key: key, started_days_ago: 200)
    make_cycle(email: "b_tier@example.com", product_key: key, overdue_days: 60)
    make_summary(email: "b_tier@example.com")

    result = ProductRepurchaseActionabilityService.call(product_key: key, reference_date: Date.current, availability_status: "in_stock")
    assert_equal 1, result.dig("tiers", "b_tier_count")
  end

  test "classifies an overdue-91-180, single-purchase customer as tier C" do
    key = "pras_#{SecureRandom.hex(4)}"
    make_cycle(email: "c_tier@example.com", product_key: key, overdue_days: 120)
    make_summary(email: "c_tier@example.com", purchase_count: 1)

    result = ProductRepurchaseActionabilityService.call(product_key: key, reference_date: Date.current, availability_status: "in_stock")
    assert_equal 1, result.dig("tiers", "c_tier_count")
  end

  test "classifies overdue beyond 180 days as dormant regardless of repurchase history" do
    key = "pras_#{SecureRandom.hex(4)}"
    make_matched_cycle(email: "dormant@example.com", product_key: key, started_days_ago: 500)
    make_cycle(email: "dormant@example.com", product_key: key, overdue_days: 300)
    make_summary(email: "dormant@example.com")

    result = ProductRepurchaseActionabilityService.call(product_key: key, reference_date: Date.current, availability_status: "in_stock")
    assert_equal 1, result.dig("tiers", "dormant_tier_count")
  end

  test "returns an empty result when there are no overdue cycles" do
    key = "pras_#{SecureRandom.hex(4)}"
    result = ProductRepurchaseActionabilityService.call(product_key: key, reference_date: Date.current, availability_status: "in_stock")

    assert_equal 0, result["total_overdue"]
    assert_equal 0, result["actionable_count"]
  end
end

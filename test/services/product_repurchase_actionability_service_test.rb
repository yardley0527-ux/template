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

  test "returns an empty result when there are no overdue cycles" do
    key = "pras_#{SecureRandom.hex(4)}"
    result = ProductRepurchaseActionabilityService.call(product_key: key, reference_date: Date.current, availability_status: "in_stock")

    assert_equal 0, result["total_overdue"]
    assert_equal 0, result["actionable_count"]
  end
end

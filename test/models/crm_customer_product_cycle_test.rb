# frozen_string_literal: true

require "test_helper"

class CrmCustomerProductCycleTest < ActiveSupport::TestCase
  def build_cycle(overrides = {})
    CrmCustomerProductCycle.new({
      identity_key: "test_#{SecureRandom.hex(4)}@example.com",
      email: "test@example.com",
      product_key: "omnipotent",
      cycle_started_at: Date.new(2026, 1, 1),
      bottle_count: 3,
      estimated_usage_days: 60,
      estimated_finish_date: Date.new(2026, 3, 2),
      suggested_contact_date: Date.new(2026, 2, 23),
      match_status: "not_yet_repurchased",
      refreshed_at: Time.current
    }.merge(overrides))
  end

  test "uniqueness on identity_key + product_key + cycle_started_at" do
    identity_key = "dup_#{SecureRandom.hex(4)}"
    build_cycle(identity_key: identity_key).save!

    dup = build_cycle(identity_key: identity_key)
    assert_not dup.valid?
  end

  test "same identity_key with a different cycle_started_at is allowed (separate cycle)" do
    identity_key = "multi_#{SecureRandom.hex(4)}"
    build_cycle(identity_key: identity_key, cycle_started_at: Date.new(2026, 1, 1)).save!

    later = build_cycle(identity_key: identity_key, cycle_started_at: Date.new(2026, 4, 1))
    assert later.valid?
  end

  test "requires match_status to be one of the known values" do
    cycle = build_cycle(match_status: "something_else")
    assert_not cycle.valid?
  end

  test "effective_finish_date defaults to estimated_finish_date when no override" do
    cycle = build_cycle
    assert_equal cycle.estimated_finish_date, cycle.effective_finish_date
    assert_not cycle.manual_override?
  end

  test "manual_override_finish_date takes priority over estimated_finish_date" do
    cycle = build_cycle(manual_override_finish_date: Date.new(2026, 5, 1))
    assert_equal Date.new(2026, 5, 1), cycle.effective_finish_date
    assert cycle.manual_override?
  end

  test "manual_override_remaining_days is anchored to manual_override_at and decays over time" do
    travel_to Date.new(2026, 2, 1) do
      cycle = build_cycle(manual_override_remaining_days: 10, manual_override_at: Time.current)
      assert_equal Date.new(2026, 2, 11), cycle.effective_finish_date
      assert_equal 10, cycle.effective_remaining_days
    end

    travel_to Date.new(2026, 2, 6) do
      cycle = build_cycle(manual_override_remaining_days: 10, manual_override_at: Time.new(2026, 2, 1))
      # 5 天過去了，剩餘天數要跟著減少，不是凍結在覆寫當下輸入的 10
      assert_equal 5, cycle.effective_remaining_days
    end
  end

  test "manual_override_remaining_days takes priority over manual_override_finish_date when both present" do
    travel_to Date.new(2026, 2, 1) do
      cycle = build_cycle(
        manual_override_remaining_days: 3,
        manual_override_finish_date: Date.new(2026, 6, 1),
        manual_override_at: Time.current
      )
      assert_equal Date.new(2026, 2, 4), cycle.effective_finish_date
    end
  end

  test "effective_overdue_days is 0 when not overdue, positive when overdue" do
    travel_to Date.new(2026, 3, 1) do
      not_overdue = build_cycle(estimated_finish_date: Date.new(2026, 3, 10))
      assert_equal 0, not_overdue.effective_overdue_days

      overdue = build_cycle(estimated_finish_date: Date.new(2026, 2, 20))
      assert_equal 9, overdue.effective_overdue_days
    end
  end

  test "next_any_order_* aliases read/write the underlying matched_next_order_* columns" do
    cycle = build_cycle(matched_next_order_number: "ORD1", matched_next_order_date: Date.new(2026, 2, 1), matched_next_product_key: "fish_oil")
    assert_equal "ORD1", cycle.next_any_order_number
    assert_equal Date.new(2026, 2, 1), cycle.next_any_order_date
    assert_equal "fish_oil", cycle.next_any_product_key
  end

  test "cross_product_purchase? is true only when the next-any order exists and differs from this cycle's product" do
    no_next = build_cycle
    assert_not no_next.cross_product_purchase?

    same_product_next = build_cycle(matched_next_order_date: Date.new(2026, 2, 1), matched_next_product_key: "omnipotent")
    assert_not same_product_next.cross_product_purchase?

    cross = build_cycle(matched_next_order_date: Date.new(2026, 2, 1), matched_next_product_key: "fish_oil")
    assert cross.cross_product_purchase?
  end

  test "same_product_repurchase_completed? and same_product_repurchase_days reflect next_same_product_order fields independently of cross_product_purchase" do
    # 跨品購買（魚油）跟同品回購（全能）同時成立時，兩條線都要能各自正確讀出來
    cycle = build_cycle(
      cycle_started_at: Date.new(2026, 6, 1),
      matched_next_order_date: Date.new(2026, 6, 15), matched_next_product_key: "fish_oil",
      next_same_product_order_date: Date.new(2026, 7, 20)
    )

    assert cycle.cross_product_purchase?
    assert cycle.same_product_repurchase_completed?
    assert_equal 49, cycle.same_product_repurchase_days
  end

  test "same_product_repurchase_days is nil when there is no next_same_product_order" do
    cycle = build_cycle
    assert_not cycle.same_product_repurchase_completed?
    assert_nil cycle.same_product_repurchase_days
  end

  test "cross_product_purchase is no longer a valid match_status value" do
    cycle = build_cycle(match_status: "cross_product_purchase")
    assert_not cycle.valid?
  end
end

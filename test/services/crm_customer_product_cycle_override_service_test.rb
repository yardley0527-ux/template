# frozen_string_literal: true

require "test_helper"

class CrmCustomerProductCycleOverrideServiceTest < ActiveSupport::TestCase
  def build_cycle
    CrmCustomerProductCycle.create!(
      identity_key: "override_test_#{SecureRandom.hex(4)}",
      email: "test@example.com", product_key: "omnipotent",
      cycle_started_at: Date.new(2026, 1, 1), bottle_count: 2,
      estimated_usage_days: 50, estimated_finish_date: Date.new(2026, 2, 20),
      suggested_contact_date: Date.new(2026, 2, 13),
      match_status: "not_yet_repurchased", refreshed_at: Time.current
    )
  end

  test "sets manual_override_remaining_days with source and timestamp" do
    cycle = build_cycle
    travel_to Date.new(2026, 2, 1) do
      CrmCustomerProductCycleOverrideService.call(cycle: cycle, remaining_days: 7, source: "boss:manual_qa")
    end

    cycle.reload
    assert_equal 7, cycle.manual_override_remaining_days
    assert_nil cycle.manual_override_finish_date
    assert_equal "boss:manual_qa", cycle.manual_override_source
    assert_equal Date.new(2026, 2, 1), cycle.manual_override_at.to_date
  end

  test "sets manual_override_finish_date and clears remaining_days when finish_date given" do
    cycle = build_cycle
    CrmCustomerProductCycleOverrideService.call(cycle: cycle, finish_date: Date.new(2026, 3, 1), source: "boss:manual_qa")

    cycle.reload
    assert_equal Date.new(2026, 3, 1), cycle.manual_override_finish_date
    assert_nil cycle.manual_override_remaining_days
  end

  test "raises without a source (保留修改來源 is mandatory)" do
    cycle = build_cycle
    assert_raises(CrmCustomerProductCycleOverrideService::InvalidOverrideError) do
      CrmCustomerProductCycleOverrideService.call(cycle: cycle, remaining_days: 7, source: "")
    end
  end

  test "raises when neither remaining_days nor finish_date is given" do
    cycle = build_cycle
    assert_raises(CrmCustomerProductCycleOverrideService::InvalidOverrideError) do
      CrmCustomerProductCycleOverrideService.call(cycle: cycle, source: "boss:manual_qa")
    end
  end
end

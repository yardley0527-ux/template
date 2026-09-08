# frozen_string_literal: true

require "test_helper"

class MembershipLevelChangeTest < ActiveSupport::TestCase
  def make_run(kind: "customers_report")
    ImportRun.create!(kind: kind, file_name: "test.xlsx", file_checksum: SecureRandom.hex(8))
  end

  def make_customer(level:)
    ShoplineCustomer.create!(shopline_id: SecureRandom.hex(12), email: "#{SecureRandom.hex(6)}@example.com",
                              membership_level: level)
  end

  test "records a genuine downgrade" do
    customer = make_customer(level: "一般會員")
    before_snapshot = { customer.shopline_id => { level: "白卡", name: customer.full_name, email: customer.email } }

    changed = MembershipLevelChange.detect_and_record!(make_run, before_snapshot)

    assert_equal 1, changed
    change = MembershipLevelChange.find_by(shopline_id: customer.shopline_id)
    assert_equal "白卡", change.from_level
    assert_equal "一般會員", change.to_level
    assert_equal "downgrade", change.direction
  end

  # Regression test for the 2026-09-08 audit: an upstream import (orders
  # workbook re-processing a stale historical row) briefly wrote the old
  # membership_level back onto the customer between two customers_report
  # runs, so every run re-detected the same already-recorded transition.
  test "does not re-record a transition whose to_level matches the customer's last recorded to_level" do
    customer = make_customer(level: "一般會員")
    before_snapshot = { customer.shopline_id => { level: "白卡", name: customer.full_name, email: customer.email } }
    MembershipLevelChange.detect_and_record!(make_run, before_snapshot)
    assert_equal 1, MembershipLevelChange.where(shopline_id: customer.shopline_id).count

    # Something reset membership_level back to 白卡 before this next run started,
    # and this run's import corrects it back to 一般會員 again.
    customer.update!(membership_level: "白卡")
    changed_again = MembershipLevelChange.detect_and_record!(make_run, before_snapshot)

    assert_equal 0, changed_again
    assert_equal 1, MembershipLevelChange.where(shopline_id: customer.shopline_id).count
  end

  test "records a second transition when the level genuinely moves further" do
    customer = make_customer(level: "銀卡")
    first_before = { customer.shopline_id => { level: "白卡", name: customer.full_name, email: customer.email } }
    MembershipLevelChange.detect_and_record!(make_run, first_before)

    customer.update!(membership_level: "金卡")
    second_before = { customer.shopline_id => { level: "銀卡", name: customer.full_name, email: customer.email } }
    changed = MembershipLevelChange.detect_and_record!(make_run, second_before)

    assert_equal 1, changed
    assert_equal 2, MembershipLevelChange.where(shopline_id: customer.shopline_id).count
    assert_equal "金卡", MembershipLevelChange.where(shopline_id: customer.shopline_id).order(:changed_at).last.to_level
  end
end

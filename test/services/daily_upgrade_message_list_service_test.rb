# frozen_string_literal: true

require "test_helper"

class DailyUpgradeMessageListServiceTest < ActiveSupport::TestCase
  def make_run
    ImportRun.create!(kind: "customers_report", file_name: "test.xlsx", file_checksum: SecureRandom.hex(8))
  end

  def make_customer(level:, email:)
    ShoplineCustomer.create!(shopline_id: SecureRandom.hex(12), email: email, membership_level: level)
  end

  test "creates one message list per upgraded tier for this import run" do
    run = make_run
    customer = make_customer(level: "白卡", email: "upgraded@example.com")
    MembershipLevelChange.create!(
      import_run: run, shopline_id: customer.shopline_id, full_name: customer.full_name, email: customer.email,
      from_level: "一般會員", to_level: "白卡", direction: "upgrade", changed_at: Time.current
    )

    result = DailyUpgradeMessageListService.call(run)

    assert_equal 1, result[:created].size
    list = MessageList.find_by(name: result[:created].first)
    assert_equal "daily_snapshot", list.source
    assert_equal "白卡", list.target_product
    assert_equal ["upgraded@example.com"], list.recipients.pluck(:email)
  end

  test "ignores downgrades and only groups upgrades by to_level" do
    run = make_run
    up_customer = make_customer(level: "銀卡", email: "up@example.com")
    down_customer = make_customer(level: "一般會員", email: "down@example.com")
    MembershipLevelChange.create!(
      import_run: run, shopline_id: up_customer.shopline_id, email: up_customer.email,
      from_level: "白卡", to_level: "銀卡", direction: "upgrade", changed_at: Time.current
    )
    MembershipLevelChange.create!(
      import_run: run, shopline_id: down_customer.shopline_id, email: down_customer.email,
      from_level: "白卡", to_level: "一般會員", direction: "downgrade", changed_at: Time.current
    )

    result = DailyUpgradeMessageListService.call(run)

    assert_equal 1, result[:created].size
    assert_match(/升級銀卡/, result[:created].first)
  end

  test "does not recreate a list that already exists for today with the same name" do
    run = make_run
    customer = make_customer(level: "金卡", email: "dup@example.com")
    MembershipLevelChange.create!(
      import_run: run, shopline_id: customer.shopline_id, email: customer.email,
      from_level: "銀卡", to_level: "金卡", direction: "upgrade", changed_at: Time.current
    )

    first = DailyUpgradeMessageListService.call(run)
    assert_equal 1, first[:created].size

    second = DailyUpgradeMessageListService.call(run)
    assert_equal 0, second[:created].size
    assert_equal 1, MessageList.where(target_product: "金卡", sent_on: Date.current).count
  end

  test "returns no lists when there are no upgrades in this import run" do
    run = make_run
    result = DailyUpgradeMessageListService.call(run)
    assert_equal [], result[:created]
  end
end

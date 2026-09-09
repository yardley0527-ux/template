# frozen_string_literal: true

require "test_helper"

class UpgradedMembersControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.create!(key: "admin", name: "Admin")
    @admin = User.create!(email: "um_admin@test.com", username: "um_admin", password: "password123", role: admin_role)
    sign_in @admin
  end

  def make_upgrade_list(level:, sent_on:, recipient_count: 1)
    list = MessageList.create!(name: "#{sent_on.strftime('%m/%d')} 升級#{level}名單", sent_on: sent_on,
                                target_product: level, source: "daily_snapshot")
    recipient_count.times do |i|
      MessageListRecipient.create!(message_list_id: list.id, email: "#{level}_#{sent_on}_#{i}@example.com")
    end
    list
  end

  test "today's tier card only counts lists sent today, not earlier this month" do
    make_upgrade_list(level: "白卡", sent_on: Date.current, recipient_count: 2)
    make_upgrade_list(level: "白卡", sent_on: Date.current.beginning_of_month, recipient_count: 5)

    get upgraded_members_path
    assert_response :success
    assert_select ".um-level-card .um-level-count", text: "2"
  end

  test "month total includes both today's and earlier-this-month's lists" do
    make_upgrade_list(level: "銀卡", sent_on: Date.current, recipient_count: 2)
    make_upgrade_list(level: "銀卡", sent_on: Date.current.beginning_of_month, recipient_count: 5)

    get upgraded_members_path
    assert_response :success
    assert_includes response.body, "7 人"
  end

  test "a list from last year does not count toward this year's total" do
    make_upgrade_list(level: "金卡", sent_on: 1.year.ago.to_date, recipient_count: 9)
    make_upgrade_list(level: "金卡", sent_on: Date.current, recipient_count: 1)

    get upgraded_members_path
    assert_response :success
    assert_includes response.body, "1 人"
    refute_includes response.body, "10 人"
  end

  test "filtering by level only shows that level's daily lists" do
    black_list = make_upgrade_list(level: "黑卡", sent_on: Date.current, recipient_count: 1)
    gold_list  = make_upgrade_list(level: "金卡", sent_on: Date.current, recipient_count: 1)

    get upgraded_members_path(level: "黑卡")

    assert_response :success
    assert_select "a[href='#{message_list_path(black_list)}']"
    assert_select "a[href='#{message_list_path(gold_list)}']", count: 0
  end

  test "defaults to the most recent month with data, not the full history" do
    this_month_list = make_upgrade_list(level: "白卡", sent_on: Date.current)
    last_month_list  = make_upgrade_list(level: "白卡", sent_on: Date.current.prev_month)

    get upgraded_members_path

    assert_response :success
    assert_select "a[href='#{message_list_path(this_month_list)}']"
    assert_select "a[href='#{message_list_path(last_month_list)}']", count: 0
  end

  test "switching the month tab shows that month's lists instead" do
    this_month_list = make_upgrade_list(level: "白卡", sent_on: Date.current)
    last_month_list  = make_upgrade_list(level: "白卡", sent_on: Date.current.prev_month)

    get upgraded_members_path(month: Date.current.prev_month.strftime("%Y-%m"))

    assert_response :success
    assert_select "a[href='#{message_list_path(last_month_list)}']"
    assert_select "a[href='#{message_list_path(this_month_list)}']", count: 0
  end

  test "an unrecognized month param falls back to the most recent month" do
    this_month_list = make_upgrade_list(level: "白卡", sent_on: Date.current)

    get upgraded_members_path(month: "not-a-real-month")

    assert_response :success
    assert_select "a[href='#{message_list_path(this_month_list)}']"
  end
end

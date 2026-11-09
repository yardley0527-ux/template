# frozen_string_literal: true

require "test_helper"

class MessageListsDailyMonthTabsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    role = Role.create!(key: "admin", name: "Admin")
    sign_in User.create!(email: "tabs_admin@test.com", username: "tabs_admin", password: "password123", role: role)
    @current = MessageList.create!(name: "本月名單", sent_on: Date.current, target_product: "全能", source: "daily_snapshot")
    @older = MessageList.create!(name: "舊月名單", sent_on: Date.current.prev_month(2), target_product: "全能", source: "daily_snapshot")
  end

  test "defaults to the latest month and hides other months" do
    get daily_message_lists_path
    assert_response :success
    assert_includes response.body, "本月名單"
    assert_not_includes response.body, "舊月名單"
    assert_select "ul.nav-tabs a.nav-link", 2
  end

  test "shows the chosen month while the weekly summary keeps this week" do
    get daily_message_lists_path(month: @older.sent_on.strftime("%Y-%m"))
    assert_response :success
    assert_includes response.body, "舊月名單"
    assert_not_includes response.body, "本月名單"
    assert_select "ul.nav-tabs a.nav-link.active", text: /#{@older.sent_on.strftime("%Y\/%m")}/
    assert_select "td span.badge", text: "全能"
    assert_not_includes response.body, "這週還沒有自動記錄的名單"
  end

  test "falls back to the latest month for an unknown month" do
    get daily_message_lists_path(month: "bad")
    assert_response :success
    assert_includes response.body, "本月名單"
  end

  test "renders with no lists" do
    MessageList.delete_all
    get daily_message_lists_path
    assert_response :success
    assert_select "ul.nav-tabs", 0
  end
end

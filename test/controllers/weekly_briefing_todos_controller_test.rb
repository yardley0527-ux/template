# frozen_string_literal: true

require "test_helper"

class WeeklyBriefingTodosControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    role = Role.create!(key: "admin", name: "Admin")
    @user = User.create!(email: "wbt_user@test.com", username: "wbt_user", password: "password123", role: role)
    @briefing = WeeklyBriefing.create!(week_start: Date.new(2026, 6, 15), week_end: Date.new(2026, 6, 21), status: "success")
    sign_in @user
  end

  test "toggle flips a todo between pending and done" do
    todo = @briefing.todos.create!(dedupe_key: "k1", title: "任務")

    patch toggle_weekly_briefing_todo_path(todo)
    assert_redirected_to weekly_briefing_path(week_start: "2026-06-15")
    assert todo.reload.done?

    patch toggle_weekly_briefing_todo_path(todo)
    assert_not todo.reload.done?
  end

  test "preview resolves the target_query and stores the count" do
    key = "ctrl_#{SecureRandom.hex(4)}"
    CrmProduct.create!(key: key, label: "控制器測試品", status: "confirmed",
                        sql_pattern: "product_name LIKE '%控制器測試品%'", regex_pattern: "控制器測試品(\\d+)")
    CrmCustomerProductCycle.create!(
      identity_key: "e1@example.com", email: "e1@example.com", product_key: key,
      cycle_started_at: Date.current - 100, bottle_count: 1, estimated_usage_days: 30,
      estimated_finish_date: Date.current - 70, suggested_contact_date: Date.current - 70,
      match_status: "not_yet_repurchased", refreshed_at: Time.current
    )
    todo = @briefing.todos.create!(dedupe_key: "k2", title: "任務",
                                    target_query: { "type" => "product_overdue", "product_key" => key, "min_days" => 1 })

    post preview_weekly_briefing_todo_path(todo)

    assert_equal 1, todo.reload.target_count
  end

  test "create_task is refused for a todo type with no matching backend task system" do
    todo = @briefing.todos.create!(dedupe_key: "k3", title: "任務", target_query: { "type" => "dormant_member", "level" => "金卡" })

    post create_task_weekly_briefing_todo_path(todo)

    assert_redirected_to weekly_briefing_path(week_start: "2026-06-15")
    follow_redirect!
    assert_includes flash[:alert].to_s, "沒有對應的既有任務系統"
  end
end

# frozen_string_literal: true

require "test_helper"

class WeeklyBriefingsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.create!(key: "admin", name: "Admin")
    @admin = User.create!(email: "wb_admin@test.com", username: "wb_admin", password: "password123", role: admin_role)
    non_admin_role = Role.create!(key: "staff", name: "Staff")
    PagePermission.create!(role: non_admin_role, controller_name: "weekly_briefings")
    @staff = User.create!(email: "wb_staff@test.com", username: "wb_staff", password: "password123", role: non_admin_role)
  end

  test "index lists history and shows an empty state when there is none" do
    sign_in @admin
    get weekly_briefings_path
    assert_response :success
  end

  test "show renders an empty-state prompt when the week has no briefing yet" do
    sign_in @admin
    get weekly_briefing_path(week_start: "2026-06-15")
    assert_response :success
    assert_includes response.body, "還沒有產生報告"
  end

  test "show renders the stored report for an existing week" do
    briefing = WeeklyBriefing.create!(week_start: Date.new(2026, 6, 15), week_end: Date.new(2026, 6, 21),
                                       status: "success", ai_report: { "one_liner" => "測試一句話" },
                                       metrics: { "revenue_progress" => { "this_week_revenue" => 1000 } })
    sign_in @admin

    get weekly_briefing_path(week_start: briefing.week_start.to_s)

    assert_response :success
    assert_includes response.body, "測試一句話"
  end

  test "current resolves to this week without needing an exact date" do
    sign_in @admin
    get weekly_briefing_path(week_start: "current")
    assert_response :success
  end

  test "regenerate is forbidden for a non-admin user" do
    sign_in @staff
    assert_no_difference -> { WeeklyBriefing.count } do
      post regenerate_weekly_briefing_path(week_start: "2026-06-15")
    end
    assert_redirected_to weekly_briefing_path(week_start: "2026-06-15")
  end
end

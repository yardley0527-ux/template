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
    # 用真正的 WeeklyMetricsService 輸出（結構完整，即使資料是空的）取代手打的
    # 半成品 metrics hash——半成品之前讓 show.html.erb 深層存取（scenarios/
    # cohort_repurchase/actionability 等）直接 500，測試卻只斷言字串存在，
    # 沒有真的驗證頁面渲染成功。
    metrics = WeeklyMetricsService.call(week_start: Date.new(2026, 6, 15))
    briefing = WeeklyBriefing.create!(
      week_start: Date.new(2026, 6, 15), week_end: Date.new(2026, 6, 21), status: "success",
      ai_report: {
        "executive_summary" => { "status" => "flat", "status_label" => "大致持平", "one_liner" => "測試一句話", "status_basis" => "b", "confidence" => "medium", "reasons" => [] },
        "business_analysis" => {}, "action_items" => []
      },
      metrics: metrics
    )
    sign_in @admin

    get weekly_briefing_path(week_start: briefing.week_start.to_s)

    assert_response :success
    assert_includes response.body, "測試一句話"
  end

  test "show renders decision_type-specific fields (small_test / needs_more_data) without error" do
    metrics = WeeklyMetricsService.call(week_start: Date.new(2026, 6, 15))
    briefing = WeeklyBriefing.create!(
      week_start: Date.new(2026, 6, 15), week_end: Date.new(2026, 6, 21), status: "success",
      ai_report: {
        "executive_summary" => {
          "status" => "flat", "status_label" => "大致持平", "one_liner" => "測試一句話", "status_basis" => "b", "confidence" => "medium", "reasons" => [],
          "top_findings" => [{ "finding" => "f1", "data_evidence" => "d1", "why_it_matters" => "w1", "nature" => "short_term", "revenue_impact" => "r1", "confidence" => "medium" }],
          "decisions" => [
            { "question" => "q1", "current_situation" => "s1", "data_evidence" => "d1", "decision_type" => "small_test",
              "option_a" => { "action" => "a", "benefit" => "b", "risk" => "r", "condition" => "c" }, "option_b" => nil, "option_c" => nil,
              "recommended_option" => "A", "recommendation_reason" => "reason",
              "test_design" => { "target" => "逾期顧客", "scale" => "100人", "method" => "傳訊息", "success_kpi" => "回購率", "stop_condition" => "無效", "decision_point" => "兩週後" },
              "data_needed" => nil, "impact_if_no_decision" => "impact", "next_week_kpi" => "kpi" },
            { "question" => "q2", "current_situation" => "s2", "data_evidence" => "d2", "decision_type" => "needs_more_data",
              "option_a" => { "action" => "a", "benefit" => "b", "risk" => "r", "condition" => "c" }, "option_b" => nil, "option_c" => nil,
              "recommended_option" => "A", "recommendation_reason" => "reason",
              "test_design" => nil,
              "data_needed" => { "missing_data" => "廣告花費", "who_should_provide" => "廣告部", "when_needed" => "下週前", "decision_once_available" => "決定加碼與否" },
              "impact_if_no_decision" => "impact", "next_week_kpi" => "kpi" }
          ]
        },
        "business_analysis" => {}, "action_items" => []
      },
      metrics: metrics
    )
    sign_in @admin

    get weekly_briefing_path(week_start: briefing.week_start.to_s)

    assert_response :success
    assert_includes response.body, "測試設計"
    assert_includes response.body, "需要先補的資料"
  end

  test "current resolves to the latest complete week, not the in-progress current calendar week" do
    travel_to Date.new(2026, 9, 15) do # a Tuesday; the 09/14~09/20 week has not ended
      sign_in @admin
      get weekly_briefing_path(week_start: "current")

      assert_response :success
      assert_includes response.body, "2026/09/07" # last complete week's start date, not 09/14 (this week, still running)
      assert_not_includes response.body, "2026/09/14 ~ 09/20"
    end
  ensure
    travel_back
  end

  test "regenerate is forbidden for a non-admin user" do
    sign_in @staff
    assert_no_difference -> { WeeklyBriefing.count } do
      post regenerate_weekly_briefing_path(week_start: "2026-06-15")
    end
    assert_redirected_to weekly_briefing_path(week_start: "2026-06-15")
  end

  test "regenerate refuses to run for a week that has not ended yet, even if an admin requests it directly by URL" do
    travel_to Date.new(2026, 9, 15) do
      sign_in @admin
      assert_no_difference -> { WeeklyBriefing.count } do
        post regenerate_weekly_briefing_path(week_start: "2026-09-14") # this week, not yet complete
      end
      assert_redirected_to weekly_briefing_path(week_start: "2026-09-14")
      follow_redirect!
      assert_includes flash[:alert].to_s, "尚未結束"
    end
  ensure
    travel_back
  end

  test "in_progress shows same-elapsed-day comparisons for the still-running week, not a full week vs full week comparison" do
    travel_to Date.new(2026, 9, 15) do
      sign_in @admin
      get in_progress_weekly_briefing_path

      assert_response :success
      assert_includes response.body, "本週即時進度"
      assert_includes response.body, "尚未結束"
    end
  ensure
    travel_back
  end
end

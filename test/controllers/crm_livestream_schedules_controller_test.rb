# frozen_string_literal: true

require "test_helper"

class CrmLivestreamSchedulesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.create!(key: "admin", name: "Admin")
    staff_role = Role.create!(key: "sched_staff", name: "Sched Staff")
    PagePermission.create!(role: staff_role, controller_name: "crm_livestream_schedules")

    @admin = User.create!(email: "schadm@test.com", username: "schadmin", password: "password123", role: admin_role)
    @csr   = User.create!(email: "schcsr@test.com", username: "schcsr", password: "password123", role: staff_role)

    @key = "sch_ctrl_#{SecureRandom.hex(4)}"
    CrmProduct.create!(key: @key, label: "測試排程控制器品", status: "confirmed",
                        sql_pattern: "product_name LIKE '%測試排程控制器品%'", regex_pattern: "測試排程控制器品(\\d+)")
    CrmRepurchaseCycleConfig.create!(product_key: @key, bottle_count: 1, median_days: 60, source: "manual")
    @livestream_date = Date.current + 30
    @schedule_date    = Date.current + 10 # 直播前，落在允許排程的範圍內
    @livestream = Livestream.create!(date: @livestream_date, title: "排程控制器測試", product_keys: [@key])

    3.times do
      CrmCustomerProductCycle.create!(
        identity_key: "sch_ctrl_#{SecureRandom.hex(4)}", email: "sch_ctrl_#{SecureRandom.hex(4)}@example.com",
        product_key: @key, cycle_started_at: Date.new(2026, 1, 1), bottle_count: 1, estimated_usage_days: 60,
        estimated_finish_date: @schedule_date - 10, suggested_contact_date: @schedule_date - 17,
        match_status: "not_yet_repurchased", refreshed_at: Time.current
      )
    end
  end

  test "非管理者無法建立排程（即使有頁面權限）" do
    sign_in @csr
    post crm_livestream_schedule_path(@livestream), params: {
      start_date: @schedule_date.to_s, end_date: @schedule_date.to_s, user_ids: [@admin.id], daily_cap: "10",
      exclude_saturday: "0", exclude_sunday: "0"
    }

    assert_response :forbidden
    assert_equal 0, CrmLivestreamOutreachTask.count
  end

  test "管理者可以預覽（不寫入 DB）並確認建立任務" do
    sign_in @admin

    assert_no_difference -> { CrmLivestreamOutreachTask.count } do
      post preview_crm_livestream_schedule_path(@livestream), params: {
        start_date: @schedule_date.to_s, end_date: @schedule_date.to_s, user_ids: [@admin.id], daily_cap: "10",
        exclude_saturday: "0", exclude_sunday: "0"
      }
    end
    assert_response :success
    assert_includes response.body, "尚未寫入資料庫"

    assert_difference -> { CrmLivestreamOutreachTask.count }, 3 do
      post crm_livestream_schedule_path(@livestream), params: {
        start_date: @schedule_date.to_s, end_date: @schedule_date.to_s, user_ids: [@admin.id], daily_cap: "10",
        exclude_saturday: "0", exclude_sunday: "0"
      }
    end
    assert_response :redirect
  end

  test "end_date 晚於直播前一天時，預覽會回傳驗證錯誤（前後端日期規則一致）" do
    sign_in @admin
    post preview_crm_livestream_schedule_path(@livestream), params: {
      start_date: @schedule_date.to_s, end_date: @livestream_date.to_s, user_ids: [@admin.id], daily_cap: "10",
      exclude_saturday: "0", exclude_sunday: "0"
    }

    assert_response :success
    assert_includes response.body, "直播後的追蹤排程"
    assert_equal 0, CrmLivestreamOutreachTask.count
  end

  test "歷史直播的 new 頁面顯示不可排程訊息" do
    past_livestream = Livestream.create!(date: Date.current - 5, title: "已結束的直播", product_keys: [@key])
    sign_in @admin
    get new_crm_livestream_schedule_path(past_livestream)

    assert_response :success
    assert_includes response.body, "已經結束"
  end
end

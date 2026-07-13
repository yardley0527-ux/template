# frozen_string_literal: true

require "test_helper"

class WelcomeControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    travel_to Time.zone.local(2026, 7, 13, 8, 0, 0)
    @user = User.create!(email: "home@test.com", username: "home_t", password: "password123")
    # 讓 stale? 為 false，首頁載入不觸發背景同步（同步會打真的 Google）
    DepartmentSheetSync.mark_run!
  end

  teardown { travel_back }

  test "homepage renders command center with countdown and lights" do
    CalendarEvent.create!(title: "品牌之夜：美白", event_type: "livestream",
                          event_date: Date.new(2026, 7, 17), time_info: "9-12")
    DepartmentUpdate.create!(department: "物流部", log_date: Date.current, content: "出貨")

    sign_in @user
    get root_path

    assert_response :success
    assert_includes response.body, "品牌之夜：美白"
    assert_includes response.body, "倒數 4 天"
    assert_includes response.body, "物流部"
    assert_includes response.body, "今日已回報"
    assert_includes response.body, "本週壽星"
  end

  test "homepage renders without any data" do
    sign_in @user
    get root_path

    assert_response :success
    assert_includes response.body, "目前沒有排定的直播"
  end

  test "homepage shows sync failure alert" do
    SyncRun.create!(source: "department_sheets", status: "failed",
                    started_at: Time.current, finished_at: Time.current)

    sign_in @user
    get root_path

    assert_includes response.body, "部門日誌同步失敗"
  end
end

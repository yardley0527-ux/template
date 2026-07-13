# frozen_string_literal: true

require "test_helper"

class MonitoringControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    travel_to Time.zone.local(2026, 7, 13, 12, 0, 0)
    admin_role = Role.create!(key: "admin", name: "Admin")
    @admin = User.create!(email: "adm@test.com", username: "boss", password: "password123", role: admin_role)
    @serena = User.create!(email: "ser@test.com", username: "serena", password: "password123", role: admin_role)
  end

  teardown { travel_back }

  test "home adoption table counts each user once per day" do
    # serena 開了兩天（其中一天開兩次，只算一次）；boss 開一天
    PageView.create!(controller_name: "welcome", action_name: "index", path: "/",
                     user_id: @serena.id, visited_at: 2.days.ago)
    PageView.create!(controller_name: "welcome", action_name: "index", path: "/",
                     user_id: @serena.id, visited_at: 2.days.ago + 3.hours)
    PageView.create!(controller_name: "welcome", action_name: "index", path: "/",
                     user_id: @serena.id, visited_at: Time.current)
    PageView.create!(controller_name: "welcome", action_name: "index", path: "/",
                     user_id: @admin.id, visited_at: Time.current)
    # 其他頁面的 view 不計入
    PageView.create!(controller_name: "customers", action_name: "index", path: "/customers",
                     user_id: @serena.id, visited_at: Time.current)
    # 超過 14 天不計入
    PageView.create!(controller_name: "welcome", action_name: "index", path: "/",
                     user_id: @admin.id, visited_at: 20.days.ago)

    sign_in @admin
    get monitoring_path

    assert_response :success
    assert_includes response.body, "戰情首頁開啟率"

    # 從渲染的表格列驗證：serena 2 天、boss 1 天（同日多次只算一次）
    serena_row = response.body[/<tr>\s*<td[^>]*>serena<\/td>.*?<\/tr>/m]
    boss_row   = response.body[/<tr>\s*<td[^>]*>boss<\/td>.*?<\/tr>/m]
    assert serena_row.present?, "serena 應出現在開啟率表格"
    assert boss_row.present?, "boss 應出現在開啟率表格"
    assert_equal 2, serena_row.scan("🟢").size
    assert_equal 1, boss_row.scan("🟢").size
  end

  test "renders empty state when nobody opened the homepage" do
    sign_in @admin
    get monitoring_path

    assert_response :success
    assert_includes response.body, "近 14 天沒有任何人打開戰情首頁"
  end
end

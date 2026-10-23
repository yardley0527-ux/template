# frozen_string_literal: true

require "test_helper"

class PageViewTrackingTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    sign_in User.create!(email: "track-admin@test.com", username: "track_admin", password: "password123", role: admin_role)
  end

  test "側邊欄的頁面都會記錄（以前漏掉的 LINE 小幫手群組頁也算）" do
    assert PageView.tracked_controllers.include?("line_bot_groups")
    assert_equal "LINE 小幫手群組", PageView.all_tracked_pages["line_bot_groups#index"]

    assert_difference -> { PageView.where(controller_name: "line_bot_groups").count }, 1 do
      get line_bot_groups_path
    end
  end

  test "JS 輪詢和監控頁本身不算使用" do
    assert_no_difference -> { PageView.count } do
      get status_imports_path, as: :json
      get monitoring_path
    end
  end
end

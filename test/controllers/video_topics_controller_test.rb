# frozen_string_literal: true

require "test_helper"

class VideoTopicsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    @admin = User.create!(email: "admin-vt@test.com", username: "admin_vt", password: "password123", role: admin_role)
    sign_in @admin
  end

  test "shows the 全能 video topics with storyboard" do
    get video_topics_path
    assert_response :success
    assert_includes @response.body, "護髮買了很多，卻常常忙到隨便吃一餐？"
    assert_includes @response.body, "孕婦可以吃方向"
    assert_not_includes @response.body, "給拍攝團隊的共用安排"
    assert_includes @response.body, "<strong>「B7＝生物素」</strong>"
  end

  test "unknown product falls back to the first product" do
    get video_topics_path(product: "nope")
    assert_response :success
    assert_includes @response.body, "好睡方向"
  end

  test "sidebar lists the page under 產品 & 策略" do
    group = SidebarEntry.all.find { |g| g[:group_title] == "產品 & 策略" }
    assert_includes group[:children].map { |c| [c[:title], c[:href]] }, ["產品拍片主題", video_topics_path]
  end
end

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
    assert_includes @response.body, "想留長髮，看到「生物素」就直接下單？"
    assert_equal 17, @response.body.scan('class="tab-pane').size
    assert_includes @response.body, "白天靠咖啡撐，晚上又捨不得放下手機？"
    assert_includes @response.body, "把明天交給紙，不交給枕頭"
    assert_equal 17, @response.body.scan("結尾互動問句").size
    assert_equal 17, @response.body.scan("15–20 秒短版剪法").size
    assert_includes @response.body, "這支依序回答的題目"
    assert_includes @response.body, "葉綠素中心＝鎂"
    assert_includes @response.body, 'id="knowledge-4"'
    assert_includes @response.body, "拍法：Vlog 快剪「老闆的一天」"
    assert_includes @response.body, "我今天第四杯了。"
    assert_includes @response.body, "知識型主題"
    assert_includes @response.body, "最近很紅的鎂到底是什麼？"
  end

  test "unknown product falls back to the first product" do
    get video_topics_path(product: "nope")
    assert_response :success
    assert_includes @response.body, "好睡方向"
  end


  test "shows 蝦紅素 categories with storyboards and first-batch list" do
    get video_topics_path(product: "astaxanthin")
    assert_response :success
    assert_equal 29, @response.body.scan('class="tab-pane').size
    assert_includes @response.body, "第一批建議先拍（8 支）"
    assert_includes @response.body, "上班族｜螢幕接力"
    assert_includes @response.body, "同系列可延伸的短影音題目"
    assert_includes @response.body, "看到97%，妳知道它指的是什麼嗎？"
    assert_includes @response.body, 'href="#topic-3-0"'
  end
  test "sidebar lists the page under 產品 & 策略" do
    group = SidebarEntry.all.find { |g| g[:group_title] == "產品 & 策略" }
    assert_includes group[:children].map { |c| [c[:title], c[:href]] }, ["產品拍片主題", video_topics_path]
  end
end

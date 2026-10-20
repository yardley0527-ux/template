# frozen_string_literal: true

require "test_helper"

class SeoReportsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    @admin = User.create!(email: "seo_admin@test.com", username: "seo_admin", password: "password123", role: admin_role)
  end

  test "沒有報告時顯示提示" do
    sign_in @admin
    get seo_reports_path
    assert_response :success
    assert_includes response.body, "還沒有 SEO 報告"
  end

  test "顯示最新報告的健康檢查與漲跌" do
    SeoDailyMetric.create!(site: "yardley", date: Date.current - 3, clicks: 120, impressions: 5000, ctr: 0.024, position: 9.1)
    SeoReport.create!(report_date: Date.current, status: "success", data: {
      "sites" => { "yardley" => {
        "data_through" => (Date.current - 3).to_s,
        "summary" => { "clicks" => 700, "impressions" => 30_000, "ctr" => 0.023, "position" => 9.0, "clicks_change_pct" => -5.0,
                       "impressions_change_pct" => 2.0, "previous" => { "clicks" => 737, "ctr" => 0.024, "position" => 8.8 } },
        "movers" => { "queries" => { "drops" => [{ "key" => "薑黃推薦", "clicks" => 10, "previous_clicks" => 40, "change" => -30,
                                                   "position" => 12.0, "previous_position" => 3.0 }], "gains" => [] },
                      "pages" => { "drops" => [], "gains" => [] } },
        "checks" => [{ "check" => "organization_schema", "label" => "Organization Schema", "url" => "https://www.yardley.tw/",
                       "level" => "warning", "detail" => "重複宣告 2 次" }]
      } }
    })

    sign_in @admin
    get seo_reports_path
    assert_response :success
    assert_includes response.body, "薑黃推薦"
    assert_includes response.body, "重複宣告 2 次"
    assert_includes response.body, "今天有 1 項需要處理"
  end

  test "SEO 報告檢視帳號登入後首頁導到 SEO 報告，其他頁面不能看" do
    role = Role.find_or_create_by!(key: "seo_viewer") { |r| r.name = "SEO 報告檢視" }
    PagePermission.find_or_create_by!(role: role, controller_name: "seo_reports")
    viewer = User.create!(email: "seo_viewer@test.com", username: "seo_viewer", password: "password123", role: role)

    sign_in viewer
    get root_path
    assert_redirected_to seo_reports_path

    get seo_reports_path
    assert_response :success

    get customers_path
    assert_redirected_to root_path
  end
end

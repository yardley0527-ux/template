# frozen_string_literal: true

require "test_helper"

# 方案 B PR4：確認所有新／改造頁面與其 export 端點都套用既有登入與
# page_permissions 機制，且無法靠「知道 export URL」繞過頁面權限。
class LivestreamAuthorizationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    @admin = User.create!(email: "authz-admin@test.com", username: "authz_admin", password: "password123", role: admin_role)

    @staff_role = Role.create!(key: "authz-staff-#{SecureRandom.hex(4)}", name: "AuthzStaff")
    @staff = User.create!(email: "authz-staff@test.com", username: "authz_staff", password: "password123", role: @staff_role)

    CrmProduct.find_or_create_by!(key: "omnipotent") { |c| c.label = "全能"; c.status = "confirmed"; c.include_in_analysis = true }
    @ls = Livestream.create!(date: Date.current - 10, product_keys: ["omnipotent"], window_days: 3)
  end

  # ── 未登入：全部導向登入頁 ───────────────────────────────────────────────

  PROTECTED_GET_PATHS = {
    "livestream_overview" => "/livestream_overview",
    "livestreams index"   => "/livestreams",
    "livestream_product_analysis" => "/livestream_product_analysis",
    "livestream_strategy index" => "/livestream_strategy",
    "livestream_strategy attendance" => "/livestream_strategy/attendance",
    "livestream_strategy sources" => "/livestream_strategy/sources",
    "livestream_strategy windows" => "/livestream_strategy/windows",
    "export_missing" => "/livestream_product_analysis/export_missing",
    "export_event"   => "/livestream_product_analysis/export_event",
    "export_action"  => "/livestream_product_analysis/export_action"
  }.freeze

  test "all new pages and export endpoints require login" do
    PROTECTED_GET_PATHS.each do |label, path|
      get path
      assert_redirected_to new_user_session_path, "#{label}（#{path}）未登入時應導向登入頁"
    end
  end

  test "livestreams show requires login" do
    get "/livestreams/#{@ls.id}"
    assert_redirected_to new_user_session_path
  end

  # ── admin：全部可存取，行為不變 ──────────────────────────────────────────

  test "admin can access every new page and export endpoint" do
    sign_in @admin
    PROTECTED_GET_PATHS.each_value do |path|
      get path
      assert_response :success, "admin 存取 #{path} 應該成功"
    end
    get "/livestreams/#{@ls.id}"
    assert_response :success
  end

  # ── staff 無權限：一律拒絕，且無法靠知道 export URL 繞過 ──────────────

  test "staff without any livestream permission is denied every new page" do
    sign_in @staff
    PROTECTED_GET_PATHS.each do |label, path|
      get path
      assert_redirected_to root_path, "#{label}（#{path}）無權限 staff 應被導回首頁"
    end
  end

  test "staff without livestream_product_analysis permission cannot reach export endpoints even knowing the URL" do
    sign_in @staff
    # 完全沒有任何直播相關權限
    %w[/livestream_product_analysis/export_missing
       /livestream_product_analysis/export_event
       /livestream_product_analysis/export_action].each do |path|
      get path
      assert_redirected_to root_path, "#{path} 不得被無權限使用者繞過"
      assert_not_equal "text/csv", @response.media_type
    end
  end

  # ── staff 有權限：可開頁與下載 CSV ───────────────────────────────────────

  test "staff with livestream_product_analysis permission can access the page and download CSVs" do
    PagePermission.create!(role: @staff_role, controller_name: "livestream_product_analysis")
    sign_in @staff

    get "/livestream_product_analysis"
    assert_response :success

    get "/livestream_product_analysis/export_missing"
    assert_response :success
    assert_match(/text\/csv/, @response.media_type)

    get "/livestream_product_analysis/export_action"
    assert_response :success
    assert_match(/text\/csv/, @response.media_type)
  end

  test "staff with only livestream_overview permission cannot reach livestream_product_analysis" do
    PagePermission.create!(role: @staff_role, controller_name: "livestream_overview")
    sign_in @staff

    get "/livestream_overview"
    assert_response :success

    get "/livestream_product_analysis"
    assert_redirected_to root_path
  end

  test "staff with livestreams permission can access index and show, but not the other 3 new pages" do
    PagePermission.create!(role: @staff_role, controller_name: "livestreams")
    sign_in @staff

    get "/livestreams"
    assert_response :success
    get "/livestreams/#{@ls.id}"
    assert_response :success

    get "/livestream_overview"
    assert_redirected_to root_path
    get "/livestream_product_analysis"
    assert_redirected_to root_path
    get "/livestream_strategy"
    assert_redirected_to root_path
  end

  test "staff with livestream_strategy permission can access all 4 tabs" do
    PagePermission.create!(role: @staff_role, controller_name: "livestream_strategy")
    sign_in @staff

    %w[/livestream_strategy /livestream_strategy/attendance /livestream_strategy/sources /livestream_strategy/windows].each do |path|
      get path
      assert_response :success, "#{path} 應該可存取"
    end
  end

  # ── 舊網址 redirect：不得讓無權限使用者繞道新頁 ──────────────────────────

  test "old route redirect target still enforces permission after following the redirect" do
    sign_in @staff
    # staff 完全沒有 livestream_product_analysis 權限
    get "/omnipotent_analysis"
    assert_response 302
    follow_redirect!
    assert_redirected_to root_path, "redirect 落地後仍應被權限擋下，不能靠轉址繞過"
  end

  test "old route redirect lands on an accessible page once staff has the migrated permission" do
    PagePermission.create!(role: @staff_role, controller_name: "livestream_product_analysis")
    sign_in @staff

    get "/omnipotent_analysis"
    assert_response 302
    follow_redirect!
    assert_response :success
  end

  # route-level `redirect()`（非 controller action）本身不經過
  # before_action，所以第一段 302 不檢查登入——但這不是繞過，因為轉址落點
  # （livestream_product_analysis）自己一樣會要求登入；未登入使用者最終仍
  # 落在登入頁，只是多一段轉址。這裡驗證的是「最終落點」，不是第一段 302。
  test "unauthenticated user following the old route redirect chain still ends up at the login page" do
    get "/omnipotent_analysis"
    assert_response 302
    follow_redirect!
    assert_redirected_to new_user_session_path, "第一段 redirect 不檢查登入，但落地頁必須要求登入，不得暴露受保護內容"
  end
end

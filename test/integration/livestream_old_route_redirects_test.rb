# frozen_string_literal: true

require "test_helper"

# 方案 B PR4：舊 5 個產品分析頁＋品牌之夜總覽的 index route，302（非 301）
# 轉址到新頁；export_* 子路由不轉址，仍指向舊 controller（未刪除）。
class LivestreamOldRouteRedirectsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    @admin = User.create!(email: "redirect-admin@test.com", username: "redirect_admin", password: "password123", role: admin_role)
    sign_in @admin
  end

  REDIRECTS = {
    "/omnipotent_analysis"   => "/livestream_product_analysis?product=omnipotent",
    "/probiotic_analysis"    => "/livestream_product_analysis?product=probiotic",
    "/turmeric_analysis"     => "/livestream_product_analysis?product=turmeric",
    "/metabolism_analysis"   => "/livestream_product_analysis?product=metabolism",
    "/glutathione_analysis"  => "/livestream_product_analysis?product=glutathione",
    "/livestream_analysis"   => "/livestream_strategy/attendance"
  }.freeze

  test "all 6 old index routes issue a 302 redirect to the expected new path" do
    REDIRECTS.each do |old_path, new_path|
      get old_path
      assert_response 302, "#{old_path} 應該回 302"
      assert_equal new_path, response.headers["Location"]&.sub(%r{\Ahttp://[^/]+}, ""), "#{old_path} 轉址目標不對"
    end
  end

  test "redirect actually lands on a working page when followed" do
    REDIRECTS.each_key do |old_path|
      get old_path
      follow_redirect!
      assert_response :success, "#{old_path} 轉址後的頁面應該正常渲染"
    end
  end

  test "export sub-routes are not redirected, still dispatch to the old controllers" do
    get "/omnipotent_analysis/export_missing"
    assert_response :success

    get "/turmeric_analysis/export_missing"
    assert_response :success
  end
end

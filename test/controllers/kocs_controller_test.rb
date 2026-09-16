# frozen_string_literal: true

require "test_helper"

class KocsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role  = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    social_role = Role.find_or_create_by!(key: "social") { |r| r.name = "社群部" }
    PagePermission.find_or_create_by!(role: social_role, controller_name: "kocs")

    @admin  = User.create!(email: "koc_admin@test.com", username: "koc_admin", password: "password123", role: admin_role)
    @social = User.create!(email: "koc_social@test.com", username: "koc_social", password: "password123", role: social_role)

    @koc = Koc.create!(ig_username: "koc_delete_test_#{SecureRandom.hex(4)}", source: "手動新增")
  end

  test "admin 能刪除 KOC" do
    sign_in @admin
    assert_difference "Koc.count", -1 do
      delete koc_path(@koc)
    end
    assert_redirected_to kocs_path
  end

  test "social 也能刪除 KOC" do
    sign_in @social
    assert_difference "Koc.count", -1 do
      delete koc_path(@koc)
    end
    assert_redirected_to kocs_path
  end

  test "social 能新增 KOC 並填 Email，跟其他品牌業配名單頁權限一致" do
    sign_in @social
    assert_difference "Koc.count", 1 do
      post kocs_path, params: { koc: { ig_username: "koc_social_new_#{SecureRandom.hex(4)}", email: "social_added@example.com" } }
    end
    assert_equal "social_added@example.com", Koc.last.email
  end

  test "social 能編輯既有 KOC 的 Email" do
    sign_in @social
    patch koc_path(@koc), params: { koc: { email: "updated_by_social@example.com" } }
    assert_equal "updated_by_social@example.com", @koc.reload.email
  end

  test "非 admin 非 social 不能刪除 KOC" do
    other_role = Role.find_or_create_by!(key: "data") { |r| r.name = "數據部" }
    PagePermission.find_or_create_by!(role: other_role, controller_name: "kocs")
    other = User.create!(email: "koc_other@test.com", username: "koc_other", password: "password123", role: other_role)

    sign_in other
    assert_no_difference "Koc.count" do
      delete koc_path(@koc)
    end
    assert_response :forbidden
  end

  # ── 2026-09-16：checkbox/select/date 改成 local:false（AJAX）後，確認
  # 「打勾還是會正確存進資料庫」——local:true/false只影響瀏覽器送出表單的
  # 方式（整頁導航 vs. XHR），不影響PATCH本身的params/路由/controller邏輯，
  # 但實際用XHR請求（含Referer header，模擬瀏覽器remote form送出時的行為）
  # 跑一次，比純理論推論更可靠。
  test "以 XHR 方式勾選 follows_chloe_ig（模擬 local:false 表單送出）會正確存進資料庫" do
    sign_in @social
    assert_not @koc.follows_chloe_ig?

    patch koc_path(@koc), params: { koc: { follows_chloe_ig: "1" } },
                           headers: { "Referer" => kocs_url }, xhr: true

    assert_response :redirect
    assert @koc.reload.follows_chloe_ig?
  end

  test "以 XHR 方式取消勾選 email_sent 會正確存進資料庫" do
    @koc.update!(email_sent: true)
    sign_in @social

    patch koc_path(@koc), params: { koc: { email_sent: "0" } },
                           headers: { "Referer" => kocs_url }, xhr: true

    assert_response :redirect
    assert_not @koc.reload.email_sent?
  end

  test "以 XHR 方式改變聯絡狀態下拉選單會正確存進資料庫" do
    sign_in @social

    patch koc_path(@koc), params: { koc: { status: "已接洽" } },
                           headers: { "Referer" => kocs_url }, xhr: true

    assert_response :redirect
    assert_equal "已接洽", @koc.reload.status
  end

  test "以 XHR 方式改變拍影片狀態下拉選單會正確存進資料庫" do
    sign_in @social

    patch koc_path(@koc), params: { koc: { video_shoot_status: "已拍攝" } },
                           headers: { "Referer" => kocs_url }, xhr: true

    assert_response :redirect
    assert_equal "已拍攝", @koc.reload.video_shoot_status
  end

  test "以 XHR 方式填公關品寄出日期會正確存進資料庫（物流欄位限admin/物流部，用admin測）" do
    sign_in @admin

    patch koc_path(@koc), params: { koc: { pr_gift_shipped_at: "2026-09-20" } },
                           headers: { "Referer" => kocs_url }, xhr: true

    assert_response :redirect
    assert_equal Date.new(2026, 9, 20), @koc.reload.pr_gift_shipped_at
  end

  # ── 2026-09-16：隱藏功能（跟刪除並存，不刪資料只是預設列表篩掉）──
  test "social 能隱藏 KOC，隱藏後不刪除資料、只是預設列表看不到" do
    sign_in @social
    assert_no_difference "Koc.count" do
      patch toggle_hidden_koc_path(@koc)
    end
    assert @koc.reload.hidden?
    assert_redirected_to kocs_path
  end

  test "admin 也能隱藏 KOC" do
    sign_in @admin
    patch toggle_hidden_koc_path(@koc)
    assert @koc.reload.hidden?
  end

  test "再次呼叫 toggle_hidden 會取消隱藏" do
    sign_in @social
    @koc.update!(hidden: true)

    patch toggle_hidden_koc_path(@koc)

    assert_not @koc.reload.hidden?
  end

  test "非 admin 非 social 不能隱藏 KOC" do
    other_role = Role.find_or_create_by!(key: "data") { |r| r.name = "數據部" }
    PagePermission.find_or_create_by!(role: other_role, controller_name: "kocs")
    other = User.create!(email: "koc_other_hide@test.com", username: "koc_other_hide", password: "password123", role: other_role)

    sign_in other
    patch toggle_hidden_koc_path(@koc)

    assert_response :forbidden
    assert_not @koc.reload.hidden?
  end

  test "index 預設不顯示已隱藏的 KOC，但加上 hidden=1 篩選時只顯示已隱藏的" do
    @koc.update!(hidden: true)
    visible_koc = Koc.create!(ig_username: "koc_visible_#{SecureRandom.hex(4)}", source: "手動新增")
    sign_in @admin

    get kocs_path
    assert_response :success
    assert_includes response.body, visible_koc.ig_username
    assert_not_includes response.body, @koc.ig_username

    get kocs_path(hidden: "1")
    assert_response :success
    assert_includes response.body, @koc.ig_username
    assert_not_includes response.body, visible_koc.ig_username
  end
end

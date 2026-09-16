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

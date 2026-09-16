# frozen_string_literal: true

require "test_helper"

# 6 個品牌業配名單頁（Koc/ReloveKoc/...）程式碼結構完全一致，完整的權限/
# CRUD/隱藏測試在 kocs_controller_test.rb；這裡只驗證 ReloveKocsController
# 這份「複製貼上」的 controller 本身接線正確（routes/model/view 沒接錯品牌），
# 不重複整套案例。
class ReloveKocsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role  = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    social_role = Role.find_or_create_by!(key: "social") { |r| r.name = "社群部" }
    PagePermission.find_or_create_by!(role: social_role, controller_name: "relove_kocs")

    @admin  = User.create!(email: "relove_admin@test.com", username: "relove_admin", password: "password123", role: admin_role)
    @social = User.create!(email: "relove_social@test.com", username: "relove_social", password: "password123", role: social_role)

    @koc = ReloveKoc.create!(ig_username: "relove_koc_test_#{SecureRandom.hex(4)}", source: "手動新增")
  end

  test "social 能隱藏／取消隱藏 ReloveKoc，且不刪除資料" do
    sign_in @social

    assert_no_difference "ReloveKoc.count" do
      patch toggle_hidden_relove_koc_path(@koc)
    end
    assert @koc.reload.hidden?

    patch toggle_hidden_relove_koc_path(@koc)
    assert_not @koc.reload.hidden?
  end

  test "非 admin 非 social 不能隱藏 ReloveKoc" do
    other_role = Role.find_or_create_by!(key: "data") { |r| r.name = "數據部" }
    PagePermission.find_or_create_by!(role: other_role, controller_name: "relove_kocs")
    other = User.create!(email: "relove_other@test.com", username: "relove_other", password: "password123", role: other_role)

    sign_in other
    patch toggle_hidden_relove_koc_path(@koc)

    assert_response :forbidden
    assert_not @koc.reload.hidden?
  end

  test "index 預設篩掉已隱藏的 ReloveKoc，hidden=1 時只顯示已隱藏的" do
    @koc.update!(hidden: true)
    visible_koc = ReloveKoc.create!(ig_username: "relove_koc_visible_#{SecureRandom.hex(4)}", source: "手動新增")
    sign_in @admin

    get relove_kocs_path
    assert_response :success
    assert_includes response.body, visible_koc.ig_username
    assert_not_includes response.body, @koc.ig_username

    get relove_kocs_path(hidden: "1")
    assert_response :success
    assert_includes response.body, @koc.ig_username
    assert_not_includes response.body, visible_koc.ig_username
  end
end

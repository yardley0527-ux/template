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
end

# frozen_string_literal: true

require "test_helper"

class KocSearchControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    @admin = User.create!(email: "koc_search_admin@test.com", username: "koc_search_admin", password: "password123", role: admin_role)
    sign_in @admin
  end

  test "no email param renders the empty prompt" do
    get koc_search_path
    assert_response :success
    assert_includes response.body, "請輸入 Email 開始搜尋"
  end

  test "blank result set for an unmatched email" do
    get koc_search_path(email: "nobody-matches-this@example.com")
    assert_response :success
    assert_includes response.body, "找不到符合"
  end

  test "finds a KOC by email across multiple brand tables and links to each brand page" do
    Koc.create!(ig_username: "hiff_koc", email: "shared@example.com", source: "手動新增")
    ReloveKoc.create!(ig_username: "relove_koc", email: "shared@example.com", source: "手動新增")

    get koc_search_path(email: "shared@example.com")
    assert_response :success
    assert_includes response.body, "Hiff 業配名單"
    assert_includes response.body, "Relove 業配名單"
    assert_includes response.body, "hiff_koc"
    assert_includes response.body, "relove_koc"
    assert_includes response.body, kocs_path(email: "shared@example.com")
    assert_includes response.body, relove_kocs_path(email: "shared@example.com")
  end

  test "does not surface brands with no match" do
    Koc.create!(ig_username: "hiff_only", email: "only_hiff@example.com", source: "手動新增")
    ReloveKoc.create!(ig_username: "relove_unrelated", email: "someone_else@example.com", source: "手動新增")

    get koc_search_path(email: "only_hiff@example.com")
    assert_response :success
    assert_includes response.body, "hiff_only"
    assert_not_includes response.body, "relove_unrelated"
  end
end

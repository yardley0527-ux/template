# frozen_string_literal: true

require "test_helper"

class KocSearchControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    @admin = User.create!(email: "koc_search_admin@test.com", username: "koc_search_admin", password: "password123", role: admin_role)
    sign_in @admin
  end

  test "no ig_username param renders the empty prompt" do
    get koc_search_path
    assert_response :success
    assert_includes response.body, "請輸入 IG 帳號開始搜尋"
  end

  test "blank result set for an unmatched ig_username" do
    get koc_search_path(ig_username: "nobody_matches_this")
    assert_response :success
    assert_includes response.body, "找不到符合"
  end

  test "finds a KOC by ig_username across multiple brand tables and links to each brand page" do
    Koc.create!(ig_username: "shared_koc", email: "hiff@example.com", source: "手動新增")
    ReloveKoc.create!(ig_username: "shared_koc", email: "relove@example.com", source: "手動新增")

    get koc_search_path(ig_username: "shared_koc")
    assert_response :success
    assert_includes response.body, "Hiff 業配名單"
    assert_includes response.body, "Relove 業配名單"
    assert_includes response.body, kocs_path(ig_username: "shared_koc")
    assert_includes response.body, relove_kocs_path(ig_username: "shared_koc")
  end

  test "strips a leading @ from the search term" do
    Koc.create!(ig_username: "at_prefixed_koc", source: "手動新增")

    get koc_search_path(ig_username: "@at_prefixed_koc")
    assert_response :success
    assert_includes response.body, "at_prefixed_koc"
  end

  test "does not surface brands with no match" do
    Koc.create!(ig_username: "hiff_only", source: "手動新增")
    ReloveKoc.create!(ig_username: "relove_unrelated", source: "手動新增")

    get koc_search_path(ig_username: "hiff_only")
    assert_response :success
    assert_includes response.body, "hiff_only"
    assert_not_includes response.body, "relove_unrelated"
  end
end

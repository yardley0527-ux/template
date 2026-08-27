# frozen_string_literal: true

require "test_helper"

class RepliedContactsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    @admin = User.create!(email: "replied_contacts_admin@test.com", username: "replied_contacts_admin", password: "password123", role: admin_role)
    sign_in @admin
  end

  test "empty state when nobody is in 已回覆 status anywhere" do
    get replied_contacts_path
    assert_response :success
    assert_includes response.body, "目前沒有「已回覆」狀態的人"
  end

  test "pulls 已回覆 contacts across brand tables and links back to each list" do
    Koc.create!(ig_username: "replied_hiff", status: "已回覆", source: "手動新增")
    Koc.create!(ig_username: "not_replied_hiff", status: "待接洽", source: "手動新增")
    ReloveKoc.create!(ig_username: "replied_relove", status: "已回覆", source: "手動新增")
    PodcastContact.create!(ig_username: "replied_podcast", status: "已回覆", source: "手動新增")

    get replied_contacts_path
    assert_response :success
    assert_includes response.body, "replied_hiff"
    assert_includes response.body, "replied_relove"
    assert_includes response.body, "replied_podcast"
    assert_not_includes response.body, "not_replied_hiff"
    assert_includes response.body, kocs_path(status: "已回覆")
    assert_includes response.body, relove_kocs_path(status: "已回覆")
    assert_includes response.body, podcast_contacts_path(status: "已回覆")
  end
end

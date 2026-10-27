# frozen_string_literal: true

require "test_helper"

class ManychatLeadsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    @admin = User.create!(email: "mc_admin@test.com", username: "mc_admin", password: "password123", role: admin_role)
  end

  test "顯示分群、來源與名單" do
    sub = ManychatSubscriber.create!(account_key: "chloechao0527", subscriber_id: 1, name: "May", ig_username: "may.lin")
    sub.manychat_interactions.create!(interacted_at: 1.hour.ago, source: "PDRN post1")
    sign_in @admin
    get manychat_leads_path
    assert_response :success
    assert_includes response.body, "PDRN post1"
    assert_includes response.body, "@may.lin"
    assert_includes response.body, "還沒買・24 小時內"
  end

  test "沒有資料時顯示提示" do
    sign_in @admin
    get manychat_leads_path
    assert_response :success
    assert_includes response.body, "還沒有 ManyChat 資料"
  end
end

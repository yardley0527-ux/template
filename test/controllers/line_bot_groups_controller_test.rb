# frozen_string_literal: true

require "test_helper"

class LineBotGroupsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    @admin = User.create!(email: "line-admin@test.com", username: "line_admin", password: "password123", role: admin_role)
    @group = LineBotGroup.create!(group_id: "Cstrategy", name: "苼莛國際-策略部")
  end

  test "admin 勾選訂閱，不認得的項目丟掉，全部取消勾選就清空" do
    sign_in @admin
    get line_bot_groups_path
    assert_response :ok
    assert_includes response.body, "苼莛國際-策略部"

    patch line_bot_group_path(@group), params: { line_bot_group: { subscriptions: ["", "order_brief", "bogus"] } }
    assert_equal ["order_brief"], @group.reload.subscriptions

    patch line_bot_group_path(@group), params: { line_bot_group: { subscriptions: [""] } }
    assert_equal [], @group.reload.subscriptions
  end
end

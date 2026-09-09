# frozen_string_literal: true

require "test_helper"

class MessageListsRecipientFlagTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.create!(key: "admin", name: "Admin")
    @admin = User.create!(email: "flag_admin@test.com", username: "flag_admin", password: "password123", role: admin_role)
    sign_in @admin

    @list = MessageList.create!(name: "測試名單", sent_on: Date.current, target_product: "白卡", source: "daily_snapshot")
    @recipient = MessageListRecipient.create!(message_list_id: @list.id, email: "a@example.com", full_name: "測試客")
  end

  test "toggles maintained flag on" do
    post toggle_message_list_recipient_flag_path, params: { recipient_id: @recipient.id, field: "maintained", value: "true" }
    assert_response :success
    assert @recipient.reload.maintained
  end

  test "toggles follow_up_needed flag off" do
    @recipient.update!(follow_up_needed: true)
    post toggle_message_list_recipient_flag_path, params: { recipient_id: @recipient.id, field: "follow_up_needed", value: "false" }
    assert_response :success
    refute @recipient.reload.follow_up_needed
  end

  test "rejects a field that is not on the allowlist" do
    post toggle_message_list_recipient_flag_path, params: { recipient_id: @recipient.id, field: "email", value: "true" }
    assert_response :bad_request
  end
end

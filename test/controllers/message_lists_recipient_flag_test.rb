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

  test "toggles a maintenance content checkbox on" do
    post update_message_list_recipient_field_path, params: { recipient_id: @recipient.id, field: "content_usage_status", value: "true" }
    assert_response :success
    assert @recipient.reload.content_usage_status
  end

  test "toggles a maintenance content checkbox off" do
    @recipient.update!(content_restock_reminder: true)
    post update_message_list_recipient_field_path, params: { recipient_id: @recipient.id, field: "content_restock_reminder", value: "false" }
    assert_response :success
    refute @recipient.reload.content_restock_reminder
  end

  test "sets maintenance_date" do
    post update_message_list_recipient_field_path, params: { recipient_id: @recipient.id, field: "maintenance_date", value: "2026-09-09" }
    assert_response :success
    assert_equal Date.new(2026, 9, 9), @recipient.reload.maintenance_date
  end

  test "sets a valid customer_status" do
    post update_message_list_recipient_field_path, params: { recipient_id: @recipient.id, field: "customer_status", value: "有需求" }
    assert_response :success
    assert_equal "有需求", @recipient.reload.customer_status
  end

  test "rejects a customer_status value that is not on the allowlist" do
    post update_message_list_recipient_field_path, params: { recipient_id: @recipient.id, field: "customer_status", value: "亂填的" }
    assert_response :bad_request
    assert_nil @recipient.reload.customer_status
  end

  test "sets next_follow_up_date" do
    post update_message_list_recipient_field_path, params: { recipient_id: @recipient.id, field: "next_follow_up_date", value: "2026-09-20" }
    assert_response :success
    assert_equal Date.new(2026, 9, 20), @recipient.reload.next_follow_up_date
  end

  test "rejects a field that is not on the allowlist" do
    post update_message_list_recipient_field_path, params: { recipient_id: @recipient.id, field: "email", value: "true" }
    assert_response :bad_request
  end
end

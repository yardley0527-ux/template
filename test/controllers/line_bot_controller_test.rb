# frozen_string_literal: true

require "test_helper"

class LineBotControllerTest < ActionDispatch::IntegrationTest
  SECRET = "test-secret"

  setup { @old = ENV["LINE_REPORT_CHANNEL_SECRET"]; ENV["LINE_REPORT_CHANNEL_SECRET"] = SECRET }
  teardown { ENV["LINE_REPORT_CHANNEL_SECRET"] = @old }

  def deliver(events, signature: nil)
    body = { events: events }.to_json
    signature ||= Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", SECRET, body))
    post "/line_bot/webhook", params: body, headers: { "X-Line-Signature" => signature, "CONTENT_TYPE" => "application/json" }
  end

  test "被邀進群組時記下 group_id，被踢出時標成 inactive" do
    deliver([{ type: "join", source: { type: "group", groupId: "Cabc" } }])
    assert_response :ok
    assert LineBotGroup.find_by(group_id: "Cabc").active

    deliver([{ type: "leave", source: { type: "group", groupId: "Cabc" } }])
    refute LineBotGroup.find_by(group_id: "Cabc").active
  end

  test "簽章不對的請求擋掉" do
    deliver([{ type: "join", source: { type: "group", groupId: "Cfake" } }], signature: "bogus")
    assert_response :bad_request
    assert_nil LineBotGroup.find_by(group_id: "Cfake")
  end

  test "LINE 後台按驗證送來的空事件回 200" do
    deliver([])
    assert_response :ok
  end
end

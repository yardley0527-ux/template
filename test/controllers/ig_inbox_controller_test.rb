require "test_helper"

class IgInboxControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    admin_role = Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" }
    sign_in User.create!(email: "ig_inbox@test.com", username: "ig_inbox", password: "password123", role: admin_role)
    @c = IgConversation.create!(account_key: "chloechao0527", conversation_id: "c1", customer_igsid: "U1", customer_username: "may.lin",
                                category: "產品功效／適合誰", sensitive: true, sensitive_reason: "懷孕")
    @c.ig_messages.create!(message_id: "m1", from_customer: true, text: "懷孕可以吃PDRN嗎", sent_at: 1.hour.ago)
    @c.refresh_state!
    IgInboxDigest.create!(day: Date.current - 1, status: "done", overview: "昨天 12 位客人私訊。",
                          suggestions: [{ "title" => "懷孕可不可以吃", "detail" => "3 人在問" }], generated_at: Time.current)
  end

  test "列出待回覆的對話、分類、敏感標記和每日總結" do
    get ig_inbox_index_path
    assert_response :success
    assert_includes response.body, "@may.lin"
    assert_includes response.body, "懷孕可以吃PDRN嗎"
    assert_includes response.body, "⚠️ 懷孕"
    assert_includes response.body, "送出回覆"
    assert_includes response.body, "昨天 12 位客人私訊。"
    assert_includes response.body, "還沒連上 Meta"
  end

  test "不用回會移到另一個分頁" do
    patch ig_inbox_path(@c), params: { status: "ignored" }
    assert_equal "ignored", @c.reload.status
    get ig_inbox_index_path
    assert_includes response.body, "目前沒有待回覆的私訊"
  end

  test "回覆失敗會顯示原因" do
    post reply_ig_inbox_path(@c), params: { text: "可以" }
    follow_redirect!
    assert_includes response.body, "找不到 chloechao0527 的 Meta 設定"
  end
end

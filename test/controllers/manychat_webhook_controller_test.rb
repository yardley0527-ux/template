# frozen_string_literal: true

require "test_helper"

class ManychatWebhookControllerTest < ActionDispatch::IntegrationTest
  TOKEN = "test-token"

  setup { @old = ENV["MANYCHAT_WEBHOOK_TOKEN"]; ENV["MANYCHAT_WEBHOOK_TOKEN"] = TOKEN }
  teardown { ENV["MANYCHAT_WEBHOOK_TOKEN"] = @old }

  def deliver(body, token: TOKEN)
    post "/manychat/webhook", params: body.to_json,
         headers: { "X-Manychat-Token" => token, "CONTENT_TYPE" => "application/json" }
  end

  test "記下訂閱者，IG 對到的客人只列候選、不回傳會員資訊；人工確認後才回傳；重送時更新同一筆" do
    customer = ShoplineCustomer.create!(full_name: "王小美", instagram_account: "may.wang", membership_level: "黑金卡")

    deliver({ account: "shengting.slim",
              subscriber: { id: 123, name: "May", ig_username: "@May.Wang", last_interaction: "2026-10-23T10:00:00+08:00" } })
    assert_response :ok
    assert_equal({ "matched" => false, "membership_level" => nil }, response.parsed_body)

    sub = ManychatSubscriber.find_by(account_key: "shengting.slim", subscriber_id: 123)
    assert_equal "may.wang", sub.ig_username
    assert_equal [customer.id], sub.candidate_customer_ids
    sub.confirm!(customer.id, user: nil)
    deliver({ account: "shengting.slim", subscriber: { id: 123 } })
    assert_equal({ "matched" => true, "membership_level" => "黑金卡" }, response.parsed_body)

    assert_no_difference -> { ManychatSubscriber.count } do
      deliver({ account: "shengting.slim", subscriber: { id: 123, name: "May W" } })
    end
    assert_equal "May W", sub.reload.name
    assert_equal "may.wang", sub.ig_username
  end

  test "對不到客人時 matched 為 false" do
    deliver({ account: "shengting.fishoil", subscriber: { id: 9, ig_username: "nobody_here" } })
    assert_response :ok
    assert_equal false, response.parsed_body["matched"]
    assert_nil ManychatSubscriber.last.shopline_customer_id
  end

  test "token 不對擋掉" do
    deliver({ account: "shengting.slim", subscriber: { id: 1 } }, token: "bogus")
    assert_response :unauthorized
    assert_equal 0, ManychatSubscriber.count
  end

  test "不在每日確認面板的帳號也收，代號大小寫與 @ 不拘" do
    deliver({ account: "@Shengting.PDRN", subscriber: { id: 5 } })
    assert_response :ok
    assert ManychatSubscriber.exists?(account_key: "shengting.pdrn", subscriber_id: 5)
  end

  test "帳號代號格式不對或缺 subscriber id 回 422" do
    deliver({ account: "苼莛 主帳號", subscriber: { id: 1 } })
    assert_response :unprocessable_entity
    deliver({ account: "", subscriber: { id: 1 } })
    assert_response :unprocessable_entity
    deliver({ account: "shengting.slim", subscriber: {} })
    assert_response :unprocessable_entity
  end

  test "Flow 事件端點：要 token，去重，不合法回 422" do
    post "/manychat/events", params: { account: "chloechao0527", subscriber_id: 5, event_type: "entry", event_id: "x1" }.to_json,
                             headers: { "X-Manychat-Token" => "wrong", "CONTENT_TYPE" => "application/json" }
    assert_response :unauthorized

    body = { account: "chloechao0527", subscriber_id: 5, event_type: "human_requested", event_id: "x1", event_time: "2026-10-29T10:00:00+08:00" }
    2.times { post "/manychat/events", params: body.to_json, headers: { "X-Manychat-Token" => TOKEN, "CONTENT_TYPE" => "application/json" } }
    assert_equal({ "ok" => true, "duplicate" => true, "event_id" => "x1" }, response.parsed_body)
    assert_equal 1, ManychatEvent.count

    post "/manychat/events", params: body.merge(event_type: "clicked").to_json, headers: { "X-Manychat-Token" => TOKEN, "CONTENT_TYPE" => "application/json" }
    assert_response :unprocessable_entity
  end
end

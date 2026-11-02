# frozen_string_literal: true

require "test_helper"

class IgInbox::SyncTest < ActiveSupport::TestCase
  ACCOUNT = IgInbox::Client::Account.new(key: "chloechao0527", page_id: "P1", ig_user_id: "IG1", token: "t")

  # minitest 6 沒有 stub：暫時換掉 Client 的 accounts / new，結束後換回來
  def with_fake_client(fake)
    meta = IgInbox::Client.singleton_class
    originals = %i[accounts new].to_h { |m| [m, IgInbox::Client.method(m)] }
    meta.send(:define_method, :accounts) { [ACCOUNT] }
    meta.send(:define_method, :new) { |*| fake }
    yield
  ensure
    originals.each { |m, orig| meta.send(:define_method, m, orig) }
  end

  def conversation(id, customer_id, messages)
    { "id" => id, "updated_time" => Time.current.iso8601,
      "participants" => { "data" => [{ "id" => "IG1", "username" => "chloechao0527" }, { "id" => customer_id, "username" => "may.lin" }] },
      "messages" => { "data" => messages.map.with_index do |(from, text, at), i|
        { "id" => "#{id}-m#{i}", "message" => text, "from" => { "id" => from }, "created_time" => at.iso8601 }
      end } }
  end

  def run_sync(data)
    fake = Object.new
    fake.define_singleton_method(:conversations) { |since:| data }
    with_fake_client(fake) { IgInbox::Sync.call }
  end

  test "客人最後講話＝待回覆；我們最後講話＝已回；重複同步不會多訊息" do
    data = [
      conversation("c1", "U1", [["U1", "全能多少錢", 2.hours.ago], ["U1", "", 1.hour.ago]]),
      conversation("c2", "U2", [["U2", "懷孕可以吃嗎", 3.hours.ago], ["IG1", "可以喔", 2.hours.ago]])
    ]
    assert_equal({ conversations: 2, messages: 4, errors: [] }, run_sync(data))

    c1 = IgConversation.find_by(conversation_id: "c1")
    assert c1.awaiting_reply
    assert_equal ["U1", "may.lin"], [c1.customer_igsid, c1.customer_username]
    assert_equal "（圖片、貼圖或分享貼文）", c1.ig_messages.order(:sent_at).last.text
    refute IgConversation.find_by(conversation_id: "c2").awaiting_reply

    assert_equal 0, run_sync(data)[:messages]
  end

  test "按過不用回的對話，客人又傳新訊息會重新打開" do
    run_sync([conversation("c1", "U1", [["U1", "嗨", 2.hours.ago]])])
    c1 = IgConversation.find_by(conversation_id: "c1")
    c1.update!(status: "ignored")

    run_sync([conversation("c1", "U1", [["U1", "嗨", 2.hours.ago], ["U1", "請問有貨嗎", 1.minute.ago]])])
    assert_equal "open", c1.reload.status
  end
end

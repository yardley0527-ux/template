# frozen_string_literal: true

require "test_helper"

class IgInbox::ReplyTest < ActiveSupport::TestCase
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

  setup do
    @conversation = IgConversation.create!(account_key: "chloechao0527", conversation_id: "c1", customer_igsid: "U1")
    @user = User.create!(email: "ig_reply@test.com", username: "boss", password: "password123")
  end

  def ask(at)
    @conversation.ig_messages.create!(message_id: "m-#{at.to_i}", from_customer: true, text: "請問", sent_at: at)
    @conversation.refresh_state!
  end

  def reply_with(text)
    sent = []
    fake = Object.new
    fake.define_singleton_method(:send_text) { |igsid, t, human_agent:| sent << [igsid, t, human_agent]; { "message_id" => "out1" } }
    with_fake_client(fake) { IgInbox::Reply.call(@conversation, text, user: @user) }
    sent
  end

  test "24 小時內直接回，送出後對話變已回並記是誰回的" do
    ask(1.hour.ago)
    assert_equal [["U1", "可以喔", false]], reply_with(" 可以喔 ")
    refute @conversation.reload.awaiting_reply
    assert_equal @user, @conversation.ig_messages.find_by(message_id: "out1").sent_by_user
  end

  test "超過 24 小時用真人客服標記，超過 7 天不能回" do
    ask(2.days.ago)
    assert_equal [["U1", "抱歉晚回", true]], reply_with("抱歉晚回")

    other = IgConversation.create!(account_key: "chloechao0527", conversation_id: "c2", customer_igsid: "U2")
    other.ig_messages.create!(message_id: "old", from_customer: true, text: "?", sent_at: 8.days.ago)
    other.refresh_state!
    @conversation = other
    assert_raises(IgInbox::Reply::Error) { reply_with("hi") }
  end
end

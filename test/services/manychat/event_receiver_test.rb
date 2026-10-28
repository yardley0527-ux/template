# frozen_string_literal: true

require "test_helper"

class Manychat::EventReceiverTest < ActiveSupport::TestCase
  setup do
    CrmProduct.create!(key: "pdrn", label: "PDRN", status: "confirmed")
  end

  def payload(overrides = {})
    { "account" => "ChloeChao0527", "subscriber_id" => "123", "event_type" => "entry", "event_id" => "e-1",
      "source_key" => "chloe-ig-pdrn-post1", "event_time" => "2026-10-29T10:00:00+08:00" }.merge(overrides)
  end

  test "entry 事件建立訂閱者、記成 flow_event 互動與首次觀測；重送同一筆不重複" do
    event, dup = Manychat::EventReceiver.call(payload)
    assert_not dup
    sub = event.manychat_subscriber
    assert_equal ["chloechao0527", 123], [sub.account_key, sub.subscriber_id]
    i = sub.manychat_interactions.sole
    assert_equal ["flow_event", "chloe-ig-pdrn-post1"], [i.event_type, i.source]
    assert_equal "chloe-ig-pdrn-post1", sub.reload.first_observed_source

    assert_no_difference -> { ManychatEvent.count + ManychatInteraction.count } do
      _, dup = Manychat::EventReceiver.call(payload)
      assert dup
    end
  end

  test "沒帶 event_id 時用內容算出固定 id，重試不重複" do
    p = payload("event_id" => nil, "event_type" => "info_requested", "properties" => { "product_key" => "pdrn" })
    first, = Manychat::EventReceiver.call(p)
    _, dup = Manychat::EventReceiver.call(p)
    assert dup
    assert first.event_id.start_with?("d:")
  end

  test "event_id、event_time 都沒帶時用收到時間，同一分鐘內重送視為同一筆" do
    t = Time.zone.parse("2026-10-29 10:00:10")
    p = payload("event_id" => nil, "event_time" => nil, "event_type" => "human_requested")
    event, = Manychat::EventReceiver.call(p, received_at: t)
    assert_equal ["received_at", t], [event.properties["event_time_from"], event.event_time]
    _, dup = Manychat::EventReceiver.call(p, received_at: t + 20)
    assert dup
  end

  test "屬性只收白名單：Email、電話不會存；產品要存在；不支援的類型拒絕" do
    event, = Manychat::EventReceiver.call(payload("event_type" => "offer_requested", "event_id" => "e-2",
                                                   "properties" => { "product_key" => "pdrn", "email" => "a@b.c", "phone" => "0912" }))
    assert_equal({ "product_key" => "pdrn" }, event.properties)

    assert_raises(Manychat::EventReceiver::Invalid) do
      Manychat::EventReceiver.call(payload("event_type" => "info_requested", "event_id" => "e-3", "properties" => { "product_key" => "nope" }))
    end
    assert_raises(Manychat::EventReceiver::Invalid) { Manychat::EventReceiver.call(payload("event_type" => "clicked_link", "event_id" => "e-4")) }
    assert_raises(Manychat::EventReceiver::Invalid) { Manychat::EventReceiver.call(payload("subscriber_id" => "abc")) }
  end

  test "同意事件必須帶渠道、用途、文字版本" do
    assert_raises(Manychat::EventReceiver::Invalid) do
      Manychat::EventReceiver.call(payload("event_type" => "consent_given", "event_id" => "c-1", "properties" => { "channel" => "line" }))
    end
    event, = Manychat::EventReceiver.call(payload("event_type" => "consent_given", "event_id" => "c-2",
                                                   "properties" => { "channel" => "line", "purpose" => "新品與優惠通知", "text_version" => "v1" }))
    assert_equal "line", event.properties["channel"]
  end
end

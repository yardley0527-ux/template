# frozen_string_literal: true

require "test_helper"

class Manychat::InteractionBackfillTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :calls

    def initialize(infos)
      @infos = infos
      @calls = []
    end

    def subscriber_info(id)
      @calls << id
      @infos.fetch(id)
    end
  end

  def info(status:, subscribed: "2026-10-27T19:44:37+08:00", last: nil, source: nil)
    { "status" => status, "subscribed" => subscribed, "ig_last_interaction" => last, "last_interaction" => nil,
      "custom_fields" => [{ "name" => "來源", "value" => source }] }
  end

  setup do
    @now = Time.zone.parse("2026-10-28 12:00")
    @active = ManychatSubscriber.create!(account_key: "chloechao0527", subscriber_id: 1, ig_username: "love_olive")
    @visitor = ManychatSubscriber.create!(account_key: "chloechao0527", subscriber_id: 2, ig_username: "sabayu")
  end

  def backfill(client)
    sync = Manychat::InteractionBackfill.new(client_factory: ->(_) { client }, now: @now)
    sync.stubs(:sleep) if sync.respond_to?(:stubs)
    sync
  end

  test "active 補最後一次互動、帶來源；visitor 只存狀態不記互動" do
    client = FakeClient.new(1 => info(status: "active", last: "2026-10-27T19:59:10+08:00", source: "PDRN post4 updated"),
                            2 => info(status: "visitor", source: "新追蹤"))

    assert_equal({ checked: 2, interactions: 1, skipped: 0, errors: [] }, backfill(client).call)

    i = @active.manychat_interactions.sole
    assert_equal Time.zone.parse("2026-10-27 19:59:10"), i.interacted_at
    assert_equal "PDRN post4 updated", i.source
    assert_equal "active", @active.reload.status
    assert_equal i.interacted_at, @active.last_interaction_at

    @visitor.reload
    assert_equal ["visitor", "新追蹤"], [@visitor.status, @visitor.source]
    assert_equal Time.zone.parse("2026-10-27 19:44:37"), @visitor.subscribed_at
    assert_empty @visitor.manychat_interactions
  end

  test "試算表已記過附近時間的互動就不重複補；查過的不再查，visitor 一小時後再查" do
    @active.manychat_interactions.create!(interacted_at: Time.zone.parse("2026-10-27 19:58:40"), source: "PDRN post4 updated")
    client = FakeClient.new(1 => info(status: "active", last: "2026-10-27T19:59:10+08:00"),
                            2 => info(status: "visitor"))

    assert_equal 0, backfill(client).call[:interactions]
    assert_equal 1, @active.manychat_interactions.count

    client.calls.clear
    backfill(client).call
    assert_empty client.calls

    @now += 61.minutes
    backfill(client).call
    assert_equal [2], client.calls
  end

  test "試算表多了新的列，下次同步要再用 API 查" do
    csv = "account,subscriber_id,ig_username,name,time\nchloechao0527,1,love_olive,,\n"
    Manychat::SheetImporter.new(nil, csv: { nil => csv }).call
    @active.reload.update_columns(api_checked_at: @now)

    Manychat::SheetImporter.new(nil, csv: { nil => csv }).call
    assert_not_nil @active.reload.api_checked_at

    Manychat::SheetImporter.new(nil, csv: { nil => csv + "chloechao0527,1,love_olive,,\n" }).call
    assert_nil @active.reload.api_checked_at
    assert_equal 2, @active.sheet_rows
  end

  test "沒有金鑰的帳號跳過" do
    assert_equal({ checked: 0, interactions: 0, skipped: 2, errors: [] }, backfill(nil).call)
  end
end

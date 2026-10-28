# frozen_string_literal: true

require "test_helper"

class Manychat::CustomerFieldSyncTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :created, :sets

    def initialize(existing = [])
      @existing = existing
      @created = []
      @sets = []
    end

    def custom_fields = @existing.map { |n| { "name" => n } }
    def create_custom_field(caption:, type:, description: nil) = @created << [caption, type]
    def set_custom_fields(id, fields) = @sets << [id, fields]
  end

  setup do
    @customer = ShoplineCustomer.create!(full_name: "王小美", instagram_account: "anyu.wang",
                                         membership_level: "黑金卡", total_amount: 82_000, order_count: 7)
    ShoplineOrder.create!(shopline_customer_id: @customer.id, order_number: "A1", product_name: "益生菌",
                          quantity: 1, order_date: Time.zone.parse("2026-08-01"))
    ShoplineOrder.create!(shopline_customer_id: @customer.id, order_number: "B2", product_name: "全能",
                          quantity: 3, order_date: Time.zone.parse("2026-09-22 10:00"))
    @sub = ManychatSubscriber.create!(account_key: "chloe.chao", subscriber_id: 1, ig_username: "anyu.wang")
    @sub.confirm!(@customer.id, user: nil)
    ManychatSubscriber.create!(account_key: "chloe.chao", subscriber_id: 2, ig_username: "nobody")
  end

  test "建缺少的欄位、寫回最近一筆訂單，內容沒變不重寫" do
    client = FakeClient.new(["卡別"])
    sync = Manychat::CustomerFieldSync.new(client_factory: ->(_) { client })
    sync.stubs(:sleep) if sync.respond_to?(:stubs)

    assert_equal({ synced: 1, skipped: 0, errors: [] }, sync.call)
    assert_equal %w[累積消費 訂單數 最近購買 最近購買日], client.created.map(&:first)
    assert_equal [1, { "卡別" => "黑金卡", "累積消費" => 82_000, "訂單數" => 7,
                       "最近購買" => "全能×3", "最近購買日" => "2026-09-22" }], client.sets.first

    assert_equal({ synced: 0, skipped: 1, errors: [] }, sync.call)
  end

  test "沒有金鑰的帳號跳過" do
    sync = Manychat::CustomerFieldSync.new(client_factory: ->(_) { nil })
    assert_equal({ synced: 0, skipped: 1, errors: [] }, sync.call)
    assert_nil @sub.reload.fields_digest
  end
end

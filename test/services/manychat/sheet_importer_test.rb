# frozen_string_literal: true

require "test_helper"

class Manychat::SheetImporterTest < ActiveSupport::TestCase
  test "同一人取最後一列、對到客人、略過缺欄位的列" do
    customer = ShoplineCustomer.create!(full_name: "王小美", instagram_account: "anyu.wang")
    csv = <<~CSV
      account,subscriber_id,ig_username,name,time
      chloe.chao,149562575,anyu.wang,Anyu,2026-10-23 10:00
      chloe.chao,149562575,anyu.wang,Anyu W,2026-10-23 11:00
      chloe.chao,,someone,No Id,
      ,123,someone,No Account,
      Chloe.Chao,999,stranger,Stranger,
    CSV

    result = Manychat::SheetImporter.new(nil, csv: { nil => csv }).call
    assert_equal({ rows: 2, created: 2, updated: 0, invalid: 0 }, result)

    sub = ManychatSubscriber.find_by(account_key: "chloe.chao", subscriber_id: 149562575)
    assert_equal "Anyu W", sub.name
    assert_equal customer.id, sub.shopline_customer_id
    assert_nil ManychatSubscriber.find_by(subscriber_id: 999).shopline_customer_id

    again = Manychat::SheetImporter.new(nil, csv: { nil => csv }).call
    assert_equal 0, again[:created]
  end

  test "account 欄空白時用分頁對應的帳號，ID 有千分位逗號也能讀" do
    csv = <<~CSV
      account,subscriber_id,ig_username,name,time
      ,"149,562,575",anyu.wang,Anyu,
    CSV
    Manychat::SheetImporter.new(nil, tabs: { "0" => "ChloeChao0527" }, csv: { "0" => csv }).call
    assert ManychatSubscriber.exists?(account_key: "chloechao0527", subscriber_id: 149562575)
  end

  test "rake manychat:sync 用的 SyncRun source 是合法值" do
    assert SyncRun.new(source: "manychat", started_at: Time.current).valid?
  end
end

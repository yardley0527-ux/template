# frozen_string_literal: true

require "test_helper"

class Manychat::SheetImporterTest < ActiveSupport::TestCase
  test "同一人取最後一列、IG 對到的客人列為候選（不自動關聯）、略過缺欄位的列" do
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
    assert_equal({ rows: 2, created: 2, updated: 0, invalid: 0, interactions: 2, rows_without_time: 1 }, result)

    sub = ManychatSubscriber.find_by(account_key: "chloe.chao", subscriber_id: 149562575)
    assert_equal "Anyu W", sub.name
    assert_nil sub.shopline_customer_id
    assert_equal ["candidate", [customer.id]], [sub.match_status, sub.candidate_customer_ids]
    assert_equal "unmatched", ManychatSubscriber.find_by(subscriber_id: 999).match_status

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

  test "每一列記成一次互動，含來源；重新同步不重複，Sheets 日期序號也讀得懂" do
    csv = <<~CSV
      account,subscriber_id,ig_username,name,time,source
      chloe.chao,1,may.lin,May,2026-10-24 20:00:00,PDRN post1
      chloe.chao,1,may.lin,May,2026-10-25 09:30:00,b群 story2
      chloe.chao,2,amy,Amy,46319.5,
    CSV

    result = Manychat::SheetImporter.new(nil, csv: { nil => csv }).call
    assert_equal 3, result[:interactions]

    may = ManychatSubscriber.find_by(subscriber_id: 1)
    assert_equal ["PDRN post1", "b群 story2"], may.manychat_interactions.order(:interacted_at).pluck(:source)
    amy = ManychatSubscriber.find_by(subscriber_id: 2).manychat_interactions.sole
    assert_equal Time.zone.local(2026, 10, 24, 12, 0), amy.interacted_at
    assert_equal "", amy.source

    assert_equal 0, Manychat::SheetImporter.new(nil, csv: { nil => csv }).call[:interactions]
  end

  test "沒有 source 欄的舊試算表照樣匯入" do
    csv = "account,subscriber_id,ig_username,name,time\nchloe.chao,5,x,X,2026-10-24 10:00\n"
    assert_equal 1, Manychat::SheetImporter.new(nil, csv: { nil => csv }).call[:interactions]
  end

  test "重複同步不新增互動；先被 API 補入的同一筆改標成試算表記錄" do
    csv = "account,subscriber_id,ig_username,name,time,source\nchloe.chao,7,x7,X,2026-10-24 10:00,PDRN post1\n"
    Manychat::SheetImporter.new(nil, csv: { nil => csv }).call
    i = ManychatInteraction.sole
    i.update_columns(event_type: "api_last_interaction")

    assert_no_difference -> { ManychatInteraction.count } do
      3.times { Manychat::SheetImporter.new(nil, csv: { nil => csv }).call }
    end
    assert_equal "sheet_row", i.reload.event_type
    assert_equal "PDRN post1", ManychatSubscriber.find_by(subscriber_id: 7).first_observed_source
  end

  test "rake manychat:sync 用的 SyncRun source 是合法值" do
    assert SyncRun.new(source: "manychat", started_at: Time.current).valid?
  end
end

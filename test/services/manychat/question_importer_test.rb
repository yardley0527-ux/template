# frozen_string_literal: true

require "test_helper"

class Manychat::QuestionImporterTest < ActiveSupport::TestCase
  CSV_TEXT = <<~CSV
    subscriber_id,ig_username,name,time,question
    "149,562,575",anyu.wang,Anyu,2026-11-01 10:00,全能可以跟益生菌一起吃嗎
    123,someone,Some,,
    456,other,Other,,懷孕可以吃PDRN嗎
  CSV

  test "每列一則、空白訊息略過、帳號用分頁對應、重複匯入不會多出來" do
    importer = Manychat::QuestionImporter.new(nil, tabs: { "0" => "Chloe.Chao" }, csv: { "0" => CSV_TEXT })
    assert_equal({ rows: 2, created: 2 }, importer.call)

    q = IgQuestion.find_by(sheet_row: 2)
    assert_equal ["chloe.chao", 149562575, "全能可以跟益生菌一起吃嗎"], [q.account_key, q.subscriber_id, q.question]
    assert_equal Time.zone.parse("2026-11-01 10:00"), q.asked_at
    assert_equal "open", q.status
    assert IgQuestion.find_by(sheet_row: 4).asked_at.present?

    assert_equal({ rows: 2, created: 0 }, importer.call)
  end

  test "沒設定分頁就不做事" do
    assert_equal({ rows: 0, created: 0 }, Manychat::QuestionImporter.new(nil, tabs: {}).call)
  end
end

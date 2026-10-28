# frozen_string_literal: true

require "test_helper"

class Marketing::CardValidatorTest < ActiveSupport::TestCase
  SNAPSHOT = {
    "data_as_of" => { "orders_to" => "2026-10-27" },
    "metrics" => [{ "id" => "m.subs.verified", "label" => "已確認身分", "value" => 7, "unit" => "人" },
                  { "id" => "m.src.1.people", "label" => "PDRN post1・30 天互動人數", "value" => 54, "unit" => "人" }],
    "segments" => [{ "id" => "seg.1", "key" => "repurchase_due", "params" => { "ahead" => 14 }, "label" => "回購機會",
                     "conditions" => "全部產品", "count" => 312, "breakdown" => { "cycle_basis" => { "historical" => 200 } } }],
    "products" => [{ "key" => "fish_oil", "label" => "魚油" }],
    "promotions" => [],
    "sources" => [{ "key" => "chloe-pdrn-post1", "name" => "PDRN post1" }]
  }.freeze

  def card(overrides = {})
    { "kind" => "segment_ops", "title" => "魚油回購提醒", "goal" => "讓 312 位回購期顧客回購", "segment_id" => "seg.1",
      "metric_ids" => ["seg.1", "m.subs.verified"], "why_now" => "其中 200 位週期依據是實際資料；PDRN post1 互動 54 人",
      "product_keys" => ["fish_oil"], "promotion_id" => nil, "content_theme" => "補貨提醒", "format" => "私訊",
      "channels" => ["ig_dm_manual"], "pre_checks" => ["確認 24 小時窗口"], "success_metric" => "14 天內有已付款訂單的人數",
      "evaluation" => "訂單資料到 10/27 之後再看 14 天", "uncertainties" => [] }.merge(overrides)
  end

  def validate(*cards) = Marketing::CardValidator.new(SNAPSHOT).call(cards)

  test "引用與數字都對得回快照的卡通過，客群人數用快照的值" do
    accepted, rejected = validate(card)
    assert_empty rejected
    assert_equal 312, accepted.first["segment_count"]
  end

  test "假造引用、自編數字、格式錯誤都會被擋下" do
    cases = {
      card("segment_id" => "seg.99") => "不存在的客群",
      card("metric_ids" => ["m.revenue.forecast"]) => "不存在的指標",
      card("product_keys" => ["nmn"]) => "不存在的產品",
      card("promotion_id" => 5) => "不存在的優惠",
      card("why_now" => "預估可帶來 120000 元營收") => "數字對不回",
      card("goal" => "提升 35% 回購") => "數字對不回",
      card("kind" => "auto_send") => "kind 不正確",
      card("channels" => ["sms_blast"]) => "不支援的管道",
      card("segment_id" => nil) => "必須指定客群",
      card.except("success_metric") => "缺少 success_metric"
    }
    cases.each do |c, reason|
      accepted, rejected = validate(c)
      assert_empty accepted, reason
      assert rejected.first["reasons"].any? { |r| r.include?(reason) }, "#{reason}：#{rejected.first['reasons']}"
    end
    assert_equal [[], [{ "reason" => "回應不是建議卡陣列" }]], Marketing::CardValidator.new(SNAPSHOT).call("drop table")
  end

  test "公開內容卡可不指定客群" do
    accepted, = validate(card("kind" => "public_content", "segment_id" => nil, "goal" => "多做 PDRN 內容", "why_now" => "PDRN post1 互動 54 人"))
    assert_equal 1, accepted.size
  end
end

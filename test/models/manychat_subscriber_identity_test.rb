# frozen_string_literal: true

require "test_helper"

class ManychatSubscriberIdentityTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "id_admin@test.com", username: "id_admin", password: "password123",
                         role: Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" })
  end

  def sub(ig, sid = rand(1..1_000_000))
    ManychatSubscriber.create!(account_key: "chloechao0527", subscriber_id: sid, ig_username: ig)
  end

  test "重複 IG 不會自動選消費最高的人，全部列為候選" do
    low = ShoplineCustomer.create!(full_name: "甲", instagram_account: "twin", total_amount: 100)
    high = ShoplineCustomer.create!(full_name: "乙", instagram_account: "@Twin", total_amount: 99_000)
    s = sub("twin")
    assert_nil s.shopline_customer_id
    assert_equal ["candidate", "ig_multiple"], [s.match_status, s.match_method]
    assert_equal [low.id, high.id].sort, s.candidate_customer_ids
  end

  test "空白、「無」等無效 IG 不比對" do
    ShoplineCustomer.create!(full_name: "甲", instagram_account: "無")
    ShoplineCustomer.create!(full_name: "乙", instagram_account: "none")
    assert_equal ["unmatched", "invalid_ig"], [sub("無").match_status, sub("無").match_method]
    assert_equal "unmatched", sub("none").match_status
    assert_equal "unmatched", sub(nil).match_status
  end

  test "人工確認寫紀錄，同步重算不會覆蓋" do
    c = ShoplineCustomer.create!(full_name: "甲", instagram_account: "may")
    s = sub("may")
    s.confirm!(c.id, user: @user, note: "訂單 IG 相同")
    assert_equal ["verified", c.id], [s.match_status, s.shopline_customer_id]
    log = s.manychat_match_logs.sole
    assert_equal ["confirm", "candidate", "verified", @user.id], [log.action, log.from_status, log.to_status, log.user_id]

    ShoplineCustomer.create!(full_name: "同 IG 新顧客", instagram_account: "may")
    ManychatSubscriber.refresh_unverified_candidates!
    assert_equal ["verified", c.id], [s.reload.match_status, s.shopline_customer_id]
  end

  test "只能確認候選名單裡的人" do
    s = sub("nobody_here")
    other = ShoplineCustomer.create!(full_name: "別人")
    assert_raises(ArgumentError) { s.confirm!(other.id, user: @user) }
    assert_not s.reload.verified?
  end

  test "排除的候選之後同步不再提出；解除關聯後排除那位、其他候選重新提出" do
    a = ShoplineCustomer.create!(full_name: "甲", instagram_account: "pair")
    b = ShoplineCustomer.create!(full_name: "乙", instagram_account: "pair")
    s = sub("pair")
    s.reject!(a.id, user: @user)
    ManychatSubscriber.refresh_unverified_candidates!
    assert_equal [b.id], s.reload.candidate_customer_ids

    s.confirm!(b.id, user: @user)
    s.unlink!(user: @user, note: "認錯人")
    assert_equal ["unmatched", nil, []], [s.match_status, s.shopline_customer_id, s.candidate_customer_ids]
    assert_equal %w[reject confirm unlink], s.manychat_match_logs.order(:id).pluck(:action)
  end

  test "首次已觀測來源不被之後的互動覆蓋，更早的觀測才會取代" do
    s = sub("obs")
    s.observe_interaction!(Time.zone.parse("2026-10-25 10:00"), "PDRN post1")
    s.observe_interaction!(Time.zone.parse("2026-10-26 10:00"), "b群1")
    assert_equal "PDRN post1", s.reload.first_observed_source
    s.observe_interaction!(Time.zone.parse("2026-10-24 10:00"), "PDRN post2")
    assert_equal "PDRN post2", s.reload.first_observed_source
  end
end

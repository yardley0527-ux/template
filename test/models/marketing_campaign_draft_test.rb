# frozen_string_literal: true

require "test_helper"

class MarketingCampaignDraftTest < ActiveSupport::TestCase
  test "草稿保存名單快照，原始資料之後變動不影響" do
    user = User.create!(email: "d@test.com", username: "drafter", password: "password123")
    c = ShoplineCustomer.create!(full_name: "甲", instagram_account: "aa")
    sub = ManychatSubscriber.create!(account_key: "chloechao0527", subscriber_id: 1, ig_username: "aa")
    sub.confirm!(c.id, user: nil)
    sub.manychat_interactions.create!(interacted_at: 1.day.ago, source: "PDRN post1")

    draft = MarketingCampaignDraft.create_from_segment!(segment_key: "recent_interactors", segment_params: { "days" => 7 }, user: user)
    assert_equal [1, "draft", Marketing::Segments::RULE_VERSION], [draft.member_count, draft.status, draft.rule_version]
    assert_equal "verified_no_purchase", draft.members.sole.snapshot["purchase_status"]

    sub.unlink!(user: user)
    sub.manychat_interactions.delete_all
    assert_equal "verified_no_purchase", draft.reload.members.sole.snapshot["purchase_status"]
    assert_equal 1, draft.member_count
  end
end

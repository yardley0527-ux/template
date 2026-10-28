# frozen_string_literal: true

require "test_helper"

class MarketingOpportunitiesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "mk_admin@test.com", username: "mk_admin", password: "password123",
                          role: Role.find_or_create_by!(key: "admin") { |r| r.name = "Admin" })
    CrmProduct.create!(key: "pdrn", label: "PDRN", status: "confirmed")
    @customer = ShoplineCustomer.create!(full_name: "王小美", instagram_account: "may.lin", email: "may@x.com")
    @sub = ManychatSubscriber.create!(account_key: "chloechao0527", subscriber_id: 1, ig_username: "may.lin", tags: ["興趣_保養"])
    @sub.manychat_interactions.create!(interacted_at: 1.day.ago, source: "PDRN post1")
    ManychatSource.create!(key: "chloe-pdrn-post1", name: "PDRN 貼文 1", account_key: "chloechao0527",
                           raw_names: ["PDRN post1"], product_keys: ["pdrn"])
  end

  test "每個分頁都能顯示，未比對的人標購買狀態未知" do
    sign_in @admin
    MarketingOpportunitiesController::TABS.each_key do |tab|
      get marketing_opportunities_path(tab: tab)
      assert_response :success, tab
    end
    get marketing_opportunities_path(tab: "interactors")
    assert_includes response.body, "候選待確認・購買狀態未知"
    assert_includes response.body, "@may.lin"
    get marketing_opportunities_path(tab: "sources")
    assert_includes response.body, "樣本不足"
    get segment_marketing_opportunities_path(key: "product_source_interest", filter: { product_key: "pdrn", days: 14 })
    assert_response :success
  end

  test "沒有頁面權限的角色看不到、也不能確認身分" do
    role = Role.create!(key: "ops", name: "營運")
    user = User.create!(email: "ops@test.com", username: "ops", password: "password123", role: role)
    sign_in user
    get marketing_opportunities_path
    assert_redirected_to root_path
    post confirm_manychat_match_path(@sub), params: { customer_id: @customer.id }
    assert_response :forbidden
    assert_not @sub.reload.verified?
  end

  test "人工確認、排除、解除都寫紀錄" do
    sign_in @admin
    get manychat_matches_path
    assert_includes response.body, "王小美"
    post confirm_manychat_match_path(@sub), params: { customer_id: @customer.id, note: "訂單 IG 相同" }
    assert @sub.reload.verified?
    post unlink_manychat_match_path(@sub), params: { note: "認錯" }
    assert_equal %w[confirm unlink], @sub.manychat_match_logs.order(:id).pluck(:action)
    assert_equal [@admin.id], @sub.manychat_match_logs.pluck(:user_id).uniq
  end

  test "從客群建立草稿；從 AI 卡建立時客群條件取自快照" do
    sign_in @admin
    post marketing_campaign_drafts_path, params: { segment_key: "recent_interactors", segment_params: { days: 7 } }
    draft = MarketingCampaignDraft.last
    assert_redirected_to edit_marketing_campaign_draft_path(draft)
    assert_equal 1, draft.member_count

    snapshot = Marketing::SnapshotBuilder.new.call
    seg = snapshot["segments"].find { |s| s["key"] == "product_source_interest" }
    suggestion = MarketingAiSuggestion.create!(status: "success", input_snapshot: snapshot, cards: [
      { "kind" => "segment_ops", "title" => "PDRN 跟進", "goal" => "跟進", "segment_id" => seg["id"], "metric_ids" => [seg["id"]],
        "product_keys" => ["pdrn"], "channels" => ["ig_dm_manual"], "pre_checks" => [], "uncertainties" => [] }
    ])
    post marketing_campaign_drafts_path, params: { suggestion_id: suggestion.id, card_index: 0, segment_params: { days: 30 } }
    draft = MarketingCampaignDraft.last
    assert_equal ["PDRN 跟進", "product_source_interest", seg["params"]], [draft.name, draft.segment_key, draft.segment_params]

    get marketing_campaign_draft_path(draft)
    assert_response :success
    assert_includes response.body, "尚未發送"
    patch marketing_campaign_draft_path(draft), params: { marketing_campaign_draft: { copy_text: "嗨～", planned_channel: "ig_story" } }
    assert_equal "嗨～", draft.reload.copy_text
  end

  test "AI 建議：按鈕觸發背景工作，產生中重按不重複" do
    sign_in @admin
    assert_difference -> { MarketingAiSuggestion.count }, 1 do
      2.times { post suggest_marketing_opportunities_path }
    end
    get marketing_opportunities_path(tab: "ai")
    assert_includes response.body, "AI 建議產生中"
  end

  test "來源設定：新增後 key 不能改，raw name 不能重複對應" do
    sign_in @admin
    get manychat_sources_path
    assert_response :success
    post manychat_sources_path, params: { manychat_source: { key: "chloe-b1", name: "b群1", account_key: "chloechao0527", raw_names_text: "PDRN post1" } }
    assert_response :unprocessable_entity
    source = ManychatSource.first
    patch manychat_source_path(source), params: { manychat_source: { key: "changed", name: "新名稱" } }
    assert_equal ["chloe-pdrn-post1", "新名稱"], [source.reload.key, source.name]
  end
end

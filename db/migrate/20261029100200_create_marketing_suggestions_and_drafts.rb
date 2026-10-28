# 行銷機會頁的 AI 建議與活動草稿。
#
# marketing_ai_suggestions：手動觸發、背景產生。input_snapshot 是送給 AI 的彙總數據
# （只含 metric／segment／product／promotion，不含姓名電話 Email 與健康資料），
# cards 是通過後端驗證的建議卡，rejected_cards 記被擋下的卡與原因。
#
# marketing_campaign_drafts：活動草稿（不代表已發送）。沒沿用 message_lists：它的 sent_on 必填
# 表示「已傳送」，成員以 email 為鍵，ManyChat 未比對的人沒有 email。
# 名單在建立當下寫進 marketing_campaign_draft_members.snapshot，之後原始資料變動不影響。
class CreateMarketingSuggestionsAndDrafts < ActiveRecord::Migration[7.1]
  def change
    create_table :marketing_ai_suggestions do |t|
      t.string   :status, null: false, default: "pending"
      t.jsonb    :input_snapshot, null: false, default: {}
      t.jsonb    :cards, null: false, default: []
      t.jsonb    :rejected_cards, null: false, default: []
      t.text     :raw_output
      t.string   :error_message
      t.string   :model
      t.string   :rule_version
      t.datetime :data_as_of
      t.integer  :attempts, null: false, default: 0
      t.datetime :started_at
      t.datetime :finished_at
      t.bigint   :requested_by_user_id
      t.timestamps
    end
    add_index :marketing_ai_suggestions, :created_at

    create_table :marketing_campaign_drafts do |t|
      t.string     :name, null: false
      t.text       :goal
      t.string     :status, null: false, default: "draft"
      t.references :marketing_ai_suggestion, foreign_key: true
      t.integer    :card_index
      t.jsonb      :card_snapshot, null: false, default: {}
      t.string     :segment_key, null: false
      t.jsonb      :segment_params, null: false, default: {}
      t.string     :rule_version, null: false
      t.integer    :member_count, null: false, default: 0
      t.string     :product_keys, array: true, null: false, default: []
      t.bigint     :promotion_snapshot_id
      t.text       :copy_text
      t.string     :planned_channel
      t.date       :planned_start_on
      t.date       :planned_end_on
      t.text       :success_metric
      t.bigint     :created_by_user_id, null: false
      t.timestamps
    end

    create_table :marketing_campaign_draft_members do |t|
      t.references :marketing_campaign_draft, null: false, foreign_key: true, index: { name: "idx_campaign_draft_members_on_draft" }
      t.bigint :manychat_subscriber_id
      t.bigint :shopline_customer_id
      t.string :identity_key, null: false
      t.jsonb  :snapshot, null: false, default: {}
    end
  end
end

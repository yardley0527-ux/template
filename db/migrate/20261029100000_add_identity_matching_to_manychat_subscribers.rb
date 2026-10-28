# ManyChat 訂閱者 ↔ 顧客改成「三段式」比對，不再自動選消費最高的人：
#   verified  — 人工確認過（只有這種才寫進 shopline_customer_id，CRM 欄位寫回、轉換統計都只看這個）
#   candidate — IG 帳號對到一位或多位顧客，待人工確認（candidate_customer_ids）
#   unmatched — 對不到，或 IG 是空白／「無」等無效值；購買狀態視為未知，不是「沒買過」
# 舊程式自動選的關聯搬到 legacy_shopline_customer_id 保留檢查，降為 candidate，不直接升級。
# rejected_customer_ids：人工排除的候選，之後同步不會再提出。人工決定記在 manychat_match_logs。
# first_observed_*：系統第一次觀測到這個人的互動（不是真正的首次接觸，追蹤開始前的互動不知道）。
class AddIdentityMatchingToManychatSubscribers < ActiveRecord::Migration[7.1]
  def up
    change_table :manychat_subscribers, bulk: true do |t|
      t.string   :match_status, null: false, default: "unmatched"
      t.string   :match_method
      t.bigint   :candidate_customer_ids, array: true, null: false, default: []
      t.bigint   :rejected_customer_ids, array: true, null: false, default: []
      t.bigint   :legacy_shopline_customer_id
      t.bigint   :match_decided_by_user_id
      t.datetime :match_decided_at
      t.jsonb    :tags, null: false, default: []
      t.datetime :tags_synced_at
      t.string   :first_observed_source
      t.datetime :first_observed_at
    end
    add_index :manychat_subscribers, :match_status

    create_table :manychat_match_logs do |t|
      t.references :manychat_subscriber, null: false, foreign_key: true
      t.bigint :user_id
      t.string :action, null: false # confirm / reject / unlink
      t.bigint :shopline_customer_id
      t.string :from_status, null: false
      t.string :to_status, null: false
      t.text :note
      t.datetime :created_at, null: false
    end

    execute <<~SQL
      UPDATE manychat_subscribers
         SET legacy_shopline_customer_id = shopline_customer_id,
             candidate_customer_ids = ARRAY[shopline_customer_id],
             match_status = 'candidate', match_method = 'legacy_auto',
             shopline_customer_id = NULL
       WHERE shopline_customer_id IS NOT NULL
    SQL
    execute <<~SQL
      UPDATE manychat_subscribers s
         SET first_observed_at = f.interacted_at, first_observed_source = f.source
        FROM (SELECT DISTINCT ON (manychat_subscriber_id) manychat_subscriber_id, interacted_at, source
                FROM manychat_interactions ORDER BY manychat_subscriber_id, interacted_at) f
       WHERE f.manychat_subscriber_id = s.id
    SQL
  end

  def down
    execute <<~SQL
      UPDATE manychat_subscribers SET shopline_customer_id = legacy_shopline_customer_id
       WHERE legacy_shopline_customer_id IS NOT NULL AND shopline_customer_id IS NULL
    SQL
    drop_table :manychat_match_logs
    remove_index :manychat_subscribers, :match_status
    change_table :manychat_subscribers, bulk: true do |t|
      t.remove :match_status, :match_method, :candidate_customer_ids, :rejected_customer_ids,
               :legacy_shopline_customer_id, :match_decided_by_user_id, :match_decided_at,
               :tags, :tags_synced_at, :first_observed_source, :first_observed_at
    end
  end
end

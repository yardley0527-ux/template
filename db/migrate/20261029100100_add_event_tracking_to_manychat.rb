# 互動事件標明來源，以及 ManyChat Flow External Request 回傳的事件。
#
# manychat_interactions.event_type：
#   sheet_row            — 試算表那一列（Flow 當下寫的時間與來源）
#   api_last_interaction — API 補的「最後一次互動」，來源是補入當下「來源」欄的值，不一定是那次互動的來源
#   flow_event           — Flow External Request 回傳的入口事件
# 部署本功能前只有 SheetImporter 寫入；10/28 12:43（台北）起 InteractionBackfill 也會寫，
# 那之後的列先標 api_last_interaction，下次同步時試算表裡有的列會被改回 sheet_row。
# synced_at 就是 created_at。
#
# manychat_sources：穩定的來源 ID（key）與可改的顯示名稱，raw_names 對應互動紀錄裡的來源字串，
# product_keys 是人工設定的「這個內容入口關聯到哪些產品」（不是客人明確表達的需求）。
#
# manychat_events：Flow External Request 事件，(account_key, event_id) 去重。
class AddEventTrackingToManychat < ActiveRecord::Migration[7.1]
  BACKFILL_DEPLOYED_AT = "2026-10-28 04:40:00" # UTC

  def up
    add_column :manychat_interactions, :event_type, :string, null: false, default: "sheet_row"
    execute <<~SQL
      UPDATE manychat_interactions SET event_type = 'api_last_interaction'
       WHERE created_at >= '#{BACKFILL_DEPLOYED_AT}'
    SQL

    create_table :manychat_sources do |t|
      t.string  :key, null: false
      t.string  :name, null: false
      t.string  :account_key, null: false
      t.string  :channel, null: false, default: "instagram"
      t.string  :content_type
      t.string  :content_ref
      t.string  :campaign_key
      t.string  :topic
      t.string  :trigger_keyword
      t.string  :flow_ns
      t.string  :flow_version
      t.string  :raw_names, array: true, null: false, default: []
      t.string  :product_keys, array: true, null: false, default: []
      t.boolean :active, null: false, default: true
      t.text    :notes
      t.bigint  :updated_by_user_id
      t.timestamps
    end
    add_index :manychat_sources, :key, unique: true
    add_index :manychat_sources, :raw_names, using: :gin

    create_table :manychat_events do |t|
      t.string     :account_key, null: false
      t.bigint     :subscriber_id, null: false
      t.references :manychat_subscriber, foreign_key: true
      t.string     :event_id, null: false
      t.string     :event_type, null: false
      t.string     :source_key
      t.string     :campaign_key
      t.string     :flow_ns
      t.string     :flow_version
      t.jsonb      :properties, null: false, default: {}
      t.datetime   :event_time, null: false
      t.datetime   :received_at, null: false
      t.timestamps
    end
    add_index :manychat_events, [:account_key, :event_id], unique: true
    add_index :manychat_events, [:event_type, :event_time]
  end

  def down
    drop_table :manychat_events
    drop_table :manychat_sources
    remove_column :manychat_interactions, :event_type
  end
end

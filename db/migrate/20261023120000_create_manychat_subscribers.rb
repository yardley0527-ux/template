# ManyChat 訂閱者 ↔ 我們客人的對應表。ManyChat API 不能用 IG 帳號反查訂閱者，
# 所以反過來：客人在 IG 私訊／留言觸發 Flow 時，Flow 的 External Request 打我們的
# webhook，記下 subscriber_id 與 ig_username，再用 IG 帳號對到 shopline_customers。
# 一個 IG 帳號（account_key）是一個 ManyChat 帳號，subscriber_id 只在該帳號內唯一。
class CreateManychatSubscribers < ActiveRecord::Migration[7.1]
  def change
    create_table :manychat_subscribers do |t|
      t.string     :account_key, null: false
      t.bigint     :subscriber_id, null: false
      t.string     :ig_username
      t.bigint     :ig_id
      t.string     :name
      t.datetime   :last_interaction_at
      t.references :shopline_customer, foreign_key: true
      t.jsonb      :raw_payload, null: false, default: {}
      t.datetime   :last_webhook_at
      t.timestamps
    end
    add_index :manychat_subscribers, [:account_key, :subscriber_id], unique: true
    add_index :manychat_subscribers, :ig_username
  end
end

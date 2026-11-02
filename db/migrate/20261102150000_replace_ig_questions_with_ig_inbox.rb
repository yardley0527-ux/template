# IG 收件匣：改用 Meta 的 Instagram 對話 API 直接抓私訊，取代 ManyChat 試算表版的 ig_questions（只上線半天、沒有資料）。
# ig_conversations：一個客人一個對話，記最後一句是誰講的（客人講的＝還沒回）、AI 分類與敏感標記。
# ig_messages：對話最近的訊息（API 每個對話只拿最近幾則，給老闆看上下文）；從 CRM 回覆的記 sent_by_user_id。
# ig_inbox_digests：每天一份 AI 整理（總結＋建議新增的自動回覆／FAQ）。
class ReplaceIgQuestionsWithIgInbox < ActiveRecord::Migration[7.1]
  def up
    drop_table :ig_questions, if_exists: true
    drop_table :ig_question_digests, if_exists: true

    create_table :ig_conversations do |t|
      t.string :account_key, null: false
      t.string :conversation_id, null: false
      t.string :customer_igsid, null: false
      t.string :customer_username
      t.datetime :last_message_at
      t.boolean :awaiting_reply, null: false, default: false
      t.datetime :last_customer_message_at
      t.string :status, null: false, default: "open"
      t.string :category
      t.boolean :sensitive, null: false, default: false
      t.string :sensitive_reason
      t.datetime :classified_at
      t.timestamps
    end
    add_index :ig_conversations, [:account_key, :conversation_id], unique: true
    add_index :ig_conversations, [:awaiting_reply, :last_customer_message_at]

    create_table :ig_messages do |t|
      t.references :ig_conversation, null: false, foreign_key: true
      t.string :message_id, null: false, index: { unique: true }
      t.boolean :from_customer, null: false
      t.text :text
      t.datetime :sent_at, null: false
      t.references :sent_by_user, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :ig_messages, [:ig_conversation_id, :sent_at]

    create_table :ig_inbox_digests do |t|
      t.date :day, null: false, index: { unique: true }
      t.string :status, null: false, default: "pending"
      t.text :overview
      t.jsonb :suggestions, null: false, default: []
      t.text :error_message
      t.datetime :generated_at
      t.timestamps
    end
  end

  def down
    drop_table :ig_inbox_digests
    drop_table :ig_messages
    drop_table :ig_conversations
  end
end

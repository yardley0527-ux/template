# Chloe 回覆助手：reply_knowledge_items 存核准過的問答，reply_drafts 存每次測試的問題、AI 草稿與核准結果。
class CreateReplyAssistantTables < ActiveRecord::Migration[7.1]
  def change
    create_table :reply_knowledge_items do |t|
      t.text :question, null: false
      t.text :answer, null: false
      t.string :source, null: false, default: "chloe"
      t.string :status, null: false, default: "approved"
      t.bigint :reviewed_by_user_id
      t.datetime :reviewed_at
      t.timestamps
    end
    add_index :reply_knowledge_items, :status

    create_table :reply_drafts do |t|
      t.text :question, null: false
      t.text :answer
      t.text :final_answer
      t.string :status, null: false, default: "generating"
      t.string :match_ref
      t.boolean :needs_human, null: false, default: false
      t.string :human_reason
      t.string :error_message
      t.bigint :created_by_user_id
      t.bigint :reviewed_by_user_id
      t.datetime :reviewed_at
      t.timestamps
    end
    add_index :reply_drafts, [:status, :created_at]
  end
end

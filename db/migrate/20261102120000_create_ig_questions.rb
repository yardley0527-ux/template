# IG 沒有被自動回覆的問題：ManyChat Default Reply 用 Insert Row 寫進試算表「未回覆問題」分頁，
# manychat:sync 匯入成 ig_questions；每天由 Claude 分類並寫一份整理（ig_question_digests），給老闆在 /ig_questions 看。
class CreateIgQuestions < ActiveRecord::Migration[7.1]
  def change
    create_table :ig_questions do |t|
      t.string :account_key, null: false
      t.string :sheet_gid, null: false, default: ""
      t.integer :sheet_row, null: false
      t.bigint :subscriber_id
      t.string :ig_username
      t.string :name
      t.text :question, null: false
      t.datetime :asked_at, null: false
      t.string :category
      t.boolean :sensitive, null: false, default: false
      t.string :sensitive_reason
      t.string :status, null: false, default: "open"
      t.timestamps
    end
    # 試算表只會往下加列，用「分頁＋第幾列」當唯一鍵，重複匯入不會多出來
    add_index :ig_questions, [:account_key, :sheet_gid, :sheet_row], unique: true, name: "index_ig_questions_uniqueness"
    add_index :ig_questions, :asked_at

    create_table :ig_question_digests do |t|
      t.date :day, null: false, index: { unique: true }
      t.string :status, null: false, default: "pending"
      t.text :overview
      t.jsonb :suggestions, null: false, default: []
      t.text :error_message
      t.datetime :generated_at
      t.timestamps
    end
  end
end

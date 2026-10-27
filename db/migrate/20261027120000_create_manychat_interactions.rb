# ManyChat 每一次互動（客人在哪篇貼文/限動觸發了哪個 automation）。
# 試算表每列就是一次互動，source 欄是 automation 在「來源」自訂欄位填的名字（如 PDRN post1）。
# 同步時整份試算表重讀，用 (訂閱者, 時間, 來源) 去重。
class CreateManychatInteractions < ActiveRecord::Migration[7.1]
  def change
    create_table :manychat_interactions do |t|
      t.references :manychat_subscriber, null: false, foreign_key: true
      t.string :source, null: false, default: ""
      t.datetime :interacted_at, null: false
      t.timestamps
    end
    add_index :manychat_interactions, [:manychat_subscriber_id, :interacted_at, :source],
              unique: true, name: "index_manychat_interactions_uniqueness"
    add_index :manychat_interactions, :interacted_at
  end
end

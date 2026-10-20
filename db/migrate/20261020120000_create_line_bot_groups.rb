# 「苼莛小幫手」LINE 機器人被邀進的群組。機器人被加進群組時 LINE 會打 webhook，
# 自動記下 group_id；被踢出時標成 inactive。每日報告推播到所有 active 群組。
class CreateLineBotGroups < ActiveRecord::Migration[7.1]
  def change
    create_table :line_bot_groups do |t|
      t.string   :group_id, null: false
      t.string   :name
      t.boolean  :active, null: false, default: true
      t.datetime :joined_at
      t.datetime :left_at
      t.timestamps
    end
    add_index :line_bot_groups, :group_id, unique: true
  end
end

class CreateDailyMemberStats < ActiveRecord::Migration[7.1]
  def change
    create_table :daily_member_stats do |t|
      t.date    :stat_date,          null: false
      # LINE
      t.integer :line_friends,       comment: "targetedReaches 好友數"
      t.integer :line_followers,     comment: "曾加入好友總計"
      t.integer :line_blocks,        comment: "封鎖數"
      # Shopline (手動或 API)
      t.integer :sl_total_members
      t.integer :sl_purchased_members
      t.integer :line_bound_members,    comment: "行動會員卡綁定人數"
      t.integer :line_and_sl_members,   comment: "官方好友+是網站會員"
      t.integer :unbound_purchased,     comment: "手機未綁定但已消費"

      t.timestamps
    end

    add_index :daily_member_stats, :stat_date, unique: true
  end
end

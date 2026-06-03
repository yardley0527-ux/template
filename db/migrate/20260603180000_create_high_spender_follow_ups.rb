class CreateHighSpenderFollowUps < ActiveRecord::Migration[7.1]
  def change
    create_table :high_spender_follow_ups do |t|
      t.string   :identity_key, null: false
      t.text     :note,         null: false
      t.datetime :followed_up_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamps
    end

    add_index :high_spender_follow_ups, :identity_key
  end
end

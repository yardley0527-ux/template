class CreateManychatChecks < ActiveRecord::Migration[7.1]
  def change
    create_table :manychat_checks do |t|
      t.date :date, null: false
      t.string :account_key, null: false
      t.string :time_slot, null: false
      t.boolean :checked, default: false, null: false
      t.bigint :checked_by_user_id
      t.datetime :checked_at
      t.text :note

      t.timestamps
    end

    add_index :manychat_checks, [:date, :account_key, :time_slot], unique: true, name: "index_manychat_checks_on_date_account_slot"
    add_index :manychat_checks, :checked_by_user_id
  end
end

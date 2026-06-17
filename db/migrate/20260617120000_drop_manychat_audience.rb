class DropManychatAudience < ActiveRecord::Migration[7.1]
  def up
    drop_table :manychat_iguids
    drop_table :manychat_snapshots
  end

  def down
    create_table :manychat_snapshots do |t|
      t.string  :account_type, null: false
      t.integer :iguid_count,  null: false, default: 0
      t.timestamps
    end

    create_table :manychat_iguids do |t|
      t.references :manychat_snapshot, null: false, foreign_key: true
      t.string :iguid, null: false
    end

    add_index :manychat_iguids, :iguid
  end
end

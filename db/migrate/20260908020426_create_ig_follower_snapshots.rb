class CreateIgFollowerSnapshots < ActiveRecord::Migration[7.1]
  def change
    create_table :ig_follower_snapshots do |t|
      t.string :account, null: false
      t.date :snapshot_date, null: false
      t.integer :followers, null: false

      t.timestamps
    end
    add_index :ig_follower_snapshots, [:account, :snapshot_date], unique: true
  end
end

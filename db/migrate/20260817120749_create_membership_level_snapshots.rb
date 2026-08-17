# frozen_string_literal: true

class CreateMembershipLevelSnapshots < ActiveRecord::Migration[7.1]
  def change
    create_table :membership_level_snapshots do |t|
      t.date :snapshot_date, null: false
      t.jsonb :counts, null: false, default: {}
      t.integer :total, null: false

      t.timestamps
    end

    add_index :membership_level_snapshots, :snapshot_date, unique: true
  end
end

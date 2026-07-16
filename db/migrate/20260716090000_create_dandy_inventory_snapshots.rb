# frozen_string_literal: true

class CreateDandyInventorySnapshots < ActiveRecord::Migration[7.1]
  def change
    create_table :dandy_inventory_snapshots do |t|
      t.date :snapshot_date, null: false, index: { unique: true }
      t.datetime :synced_at, null: false
      t.date :latest_entry_date
      t.jsonb :data, null: false, default: {}

      t.timestamps
    end
  end
end

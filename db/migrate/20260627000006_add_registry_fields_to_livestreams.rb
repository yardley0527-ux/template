class AddRegistryFieldsToLivestreams < ActiveRecord::Migration[7.1]
  def change
    change_table :livestreams, bulk: true do |t|
      t.text :analysis_note

      t.string  :product_keys, array: true, default: [], null: false
      t.integer :total_orders, default: 0, null: false
      t.decimal :total_revenue, precision: 14, scale: 2, default: 0, null: false

      t.integer :level_black_count,  default: 0, null: false
      t.decimal :level_black_amount, precision: 14, scale: 2, default: 0, null: false

      t.integer :level_gold_count,  default: 0, null: false
      t.decimal :level_gold_amount, precision: 14, scale: 2, default: 0, null: false

      t.integer :level_silver_count,  default: 0, null: false
      t.decimal :level_silver_amount, precision: 14, scale: 2, default: 0, null: false

      t.integer :level_white_count,  default: 0, null: false
      t.decimal :level_white_amount, precision: 14, scale: 2, default: 0, null: false

      t.integer :level_normal_count,  default: 0, null: false
      t.decimal :level_normal_amount, precision: 14, scale: 2, default: 0, null: false
    end

    add_index :livestreams, :product_keys, using: :gin
  end
end

class CreateCrmRepurchaseCycleConfigs < ActiveRecord::Migration[7.1]
  def change
    create_table :crm_repurchase_cycle_configs do |t|
      t.string  :product_key,  null: false, limit: 50
      t.integer :bottle_count, null: false
      t.integer :median_days,  null: false
      t.integer :sample_size,  null: false, default: 0
      t.string  :source,       null: false, default: "manual"
      t.text    :notes

      t.timestamps
    end

    add_index :crm_repurchase_cycle_configs,
              [:product_key, :bottle_count],
              unique: true,
              name: "idx_cycle_configs_on_product_bottle"
  end
end

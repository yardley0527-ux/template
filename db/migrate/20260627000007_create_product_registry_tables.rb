class CreateProductRegistryTables < ActiveRecord::Migration[7.1]
  def change
    create_table :crm_products do |t|
      t.string   :key, null: false
      t.string   :label, null: false
      t.string   :status, null: false, default: "candidate"
      t.boolean  :include_in_analysis, null: false, default: false
      t.string   :source
      t.string   :regex_pattern
      t.string   :sql_pattern
      t.datetime :reviewed_at
      t.bigint   :reviewed_by_user_id
      t.text     :notes

      t.timestamps
    end

    add_index :crm_products, :key, unique: true
    add_index :crm_products, :status

    add_foreign_key :crm_products, :users, column: :reviewed_by_user_id

    create_table :product_name_mappings do |t|
      t.string   :raw_name, null: false
      t.string   :source, null: false
      t.integer  :occurrence_count, null: false, default: 0
      t.bigint   :crm_product_id
      t.string   :mapping_status, null: false, default: "pending"
      t.bigint   :suggested_crm_product_id
      t.string   :suggested_confidence
      t.datetime :reviewed_at
      t.bigint   :reviewed_by_user_id

      t.timestamps
    end

    add_index :product_name_mappings, [:raw_name, :source], unique: true
    add_index :product_name_mappings, :mapping_status
    add_index :product_name_mappings, :source
    add_index :product_name_mappings, :crm_product_id
    add_index :product_name_mappings, :suggested_crm_product_id

    add_foreign_key :product_name_mappings, :crm_products, column: :crm_product_id
    add_foreign_key :product_name_mappings, :crm_products, column: :suggested_crm_product_id
    add_foreign_key :product_name_mappings, :users, column: :reviewed_by_user_id
  end
end

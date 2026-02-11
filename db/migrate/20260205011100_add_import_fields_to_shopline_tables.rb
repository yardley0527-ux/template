# path: db/migrate/20260205011100_add_import_fields_to_shopline_tables.rb
class AddImportFieldsToShoplineTables < ActiveRecord::Migration[7.0]
  def change
    change_table :shopline_customers, bulk: true do |t|
      t.bigint :import_run_id
      t.string :source_row_hash
    end
    add_index :shopline_customers, :import_run_id
    add_index :shopline_customers, :source_row_hash, unique: true

    change_table :shopline_orders, bulk: true do |t|
      t.bigint :import_run_id
      t.integer :source_year
      t.integer :source_month
      t.string :source_row_hash
    end
    add_index :shopline_orders, :import_run_id
    add_index :shopline_orders, [:source_year, :source_month]
    add_index :shopline_orders, :source_row_hash, unique: true
  end
end

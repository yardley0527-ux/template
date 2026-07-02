# frozen_string_literal: true

# Epic E2-2: Mapping History foundation.
#
# Stores one row per status transition on any ProductNameMapping.
# Read by: BulkConfirmService, BulkIgnoreService, ManualReview, API, audit reports.
#
# mapping_version is scoped per mapping (not global) — first confirm = 1, undo = 2, etc.
# performed_at is intentionally absent; created_at IS the event timestamp.
class CreateProductNameMappingLogs < ActiveRecord::Migration[7.1]
  def change
    create_table :product_name_mapping_logs do |t|
      t.references :product_name_mapping,
                   null: false,
                   foreign_key: true,
                   index: true

      t.integer :mapping_version, null: false

      t.string :action,        null: false
      t.string :change_source, null: false
      t.string :from_status,   null: false
      t.string :to_status,     null: false

      t.bigint :old_crm_product_id
      t.bigint :new_crm_product_id
      t.bigint :performed_by_user_id

      t.text :notes

      t.timestamps
    end

    add_index :product_name_mapping_logs, :action
    add_index :product_name_mapping_logs, :change_source
    add_index :product_name_mapping_logs, :performed_by_user_id
    add_index :product_name_mapping_logs,
              [:product_name_mapping_id, :mapping_version],
              name: "idx_pnml_mapping_version"

    add_foreign_key :product_name_mapping_logs, :crm_products,
                    column: :old_crm_product_id
    add_foreign_key :product_name_mapping_logs, :crm_products,
                    column: :new_crm_product_id
    add_foreign_key :product_name_mapping_logs, :users,
                    column: :performed_by_user_id
  end
end

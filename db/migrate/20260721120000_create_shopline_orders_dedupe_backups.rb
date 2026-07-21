# frozen_string_literal: true

# Backup table for ShoplineOrdersDedupeService's apply step. Every row it
# deletes (the total_amount-NULL half of a confirmed pattern-A duplicate
# pair) is copied here in the same transaction as the delete, so cleanup is
# reversible: `INSERT INTO shopline_orders SELECT ... FROM
# shopline_orders_dedupe_backups WHERE dedupe_run_id = ?` restores exactly
# what was removed. No PII beyond what shopline_orders itself already holds
# (email) — this table has the same retention/access posture as the source.
class CreateShoplineOrdersDedupeBackups < ActiveRecord::Migration[7.1]
  def change
    create_table :shopline_orders_dedupe_backups do |t|
      t.bigint :original_id, null: false
      t.bigint :kept_id, null: false
      t.string :dedupe_run_id, null: false
      t.string :order_number
      t.string :product_name
      t.integer :quantity
      t.decimal :checkout_amount, precision: 14, scale: 2
      t.decimal :total_amount, precision: 14, scale: 2
      t.string :email
      t.datetime :order_date
      t.bigint :import_run_id
      t.datetime :created_at, null: false

      t.index :original_id
      t.index :dedupe_run_id
    end
  end
end

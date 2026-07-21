# frozen_string_literal: true

# Backup table for ShoplineOrdersDedupeService's apply step. Every row it
# deletes (the total_amount-NULL half of a confirmed pattern-A duplicate
# pair) is copied here in the same transaction as the delete. Restore via
# `RUN_ID=<dedupe_run_id> APPLY=1 bin/rails shopline_orders:restore_dedupe_run`
# (ShoplineOrdersRestoreService) — scoped to one dedupe_run_id, never "all
# backups ever". No PII beyond what shopline_orders itself already holds
# (email) — this table has the same retention/access posture as the source.
#
# down is guarded: if this table has ever backed up a real apply run, it is
# the ONLY copy of the rows ShoplineOrdersDedupeService deleted. Rolling
# back this migration with data present would drop that irrecoverably —
# `down` refuses and raises instead of silently discarding it. There is no
# non-destructive automatic path past this: an operator who is certain the
# backups are no longer needed must explicitly `DELETE FROM
# shopline_orders_dedupe_backups` (or archive them) before rollback can
# proceed — see the deployment runbook.
class CreateShoplineOrdersDedupeBackups < ActiveRecord::Migration[7.1]
  def up
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

  def down
    count = execute("SELECT COUNT(*) FROM shopline_orders_dedupe_backups").first["count"].to_i
    if count.positive?
      raise ActiveRecord::IrreversibleMigration,
        "shopline_orders_dedupe_backups has #{count} row(s) — this is the ONLY copy of data " \
        "ShoplineOrdersDedupeService deleted. Refusing to drop the table and lose it. " \
        "If you are certain these backups are no longer needed, explicitly " \
        "`DELETE FROM shopline_orders_dedupe_backups` (or archive them elsewhere) first, " \
        "then re-run this rollback."
    end

    drop_table :shopline_orders_dedupe_backups
  end
end

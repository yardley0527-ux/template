# frozen_string_literal: true

# Tracks whether a backed-up row has already been restored, so
# ShoplineOrdersRestoreService is trivially idempotent by construction
# (running restore twice just finds zero pending rows the second time)
# rather than needing fuzzy content-matching to detect "already restored".
class AddRestoredAtToShoplineOrdersDedupeBackups < ActiveRecord::Migration[7.1]
  def change
    add_column :shopline_orders_dedupe_backups, :restored_at, :datetime
    add_index :shopline_orders_dedupe_backups, [:dedupe_run_id, :restored_at]
  end
end

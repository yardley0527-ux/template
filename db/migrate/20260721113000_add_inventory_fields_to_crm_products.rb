# frozen_string_literal: true

# 庫存狀態欄位（Notification Board Phase 0A 前置）。
# 與既有 status（映射審核狀態：candidate/confirmed/merged/ignored）完全獨立 —
# availability_status 只描述「現在買不買得到」。
class AddInventoryFieldsToCrmProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :crm_products, :availability_status, :string, null: false, default: "unknown"
    add_column :crm_products, :expected_restock_date, :date
    add_column :crm_products, :actual_restock_date, :date
    add_column :crm_products, :inventory_status_updated_at, :datetime
    add_column :crm_products, :inventory_status_updated_by_id, :bigint
    add_column :crm_products, :inventory_note, :text

    add_index :crm_products, :availability_status
    add_foreign_key :crm_products, :users, column: :inventory_status_updated_by_id
  end
end

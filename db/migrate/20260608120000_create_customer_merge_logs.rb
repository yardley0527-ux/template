class CreateCustomerMergeLogs < ActiveRecord::Migration[7.1]
  def change
    create_table :customer_merge_logs do |t|
      t.bigint   :orphan_customer_id,      null: false
      t.bigint   :official_customer_id,    null: false
      t.jsonb    :orphan_snapshot,         null: false, default: {}
      t.integer  :reassigned_orders_count, null: false, default: 0
      t.string   :merged_by
      t.timestamps
    end

    add_index :customer_merge_logs, :orphan_customer_id
    add_index :customer_merge_logs, :official_customer_id
  end
end

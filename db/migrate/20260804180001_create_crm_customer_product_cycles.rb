class CreateCrmCustomerProductCycles < ActiveRecord::Migration[7.1]
  def change
    create_table :crm_customer_product_cycles do |t|
      t.string   :identity_key,               null: false, limit: 255
      t.string   :email,                      null: false, limit: 255
      t.string   :product_key,                null: false, limit: 50
      t.date     :cycle_started_at,           null: false
      t.string   :source_order_number,        limit: 100
      t.integer  :bottle_count,               null: false
      t.integer  :estimated_usage_days,       null: false
      t.date     :estimated_finish_date,      null: false
      t.date     :suggested_contact_date,     null: false

      # 同品回購 / cross_product_purchase 跨品購買 / same_product_addon 同品加購 / not_yet_repurchased 尚未回購
      t.string   :match_status,               null: false, default: "not_yet_repurchased"
      t.string   :matched_next_order_number,  limit: 100
      t.date     :matched_next_order_date
      t.string   :matched_next_product_key,   limit: 50
      t.datetime :matched_at

      t.integer  :manual_override_remaining_days
      t.date     :manual_override_finish_date
      t.string   :manual_override_source,     limit: 255
      t.datetime :manual_override_at

      t.datetime :refreshed_at,               null: false

      t.timestamps
    end

    add_index :crm_customer_product_cycles,
              [:identity_key, :product_key, :cycle_started_at],
              unique: true,
              name: "idx_cycles_on_identity_product_cycle"

    add_index :crm_customer_product_cycles,
              [:product_key, :suggested_contact_date],
              name: "idx_cycles_on_product_contact_date"

    add_index :crm_customer_product_cycles,
              [:match_status],
              name: "idx_cycles_on_match_status"

    add_index :crm_customer_product_cycles,
              [:source_order_number],
              name: "idx_cycles_on_source_order_number"
  end
end

class CreateCrmCustomerProductTrackings < ActiveRecord::Migration[7.1]
  def change
    create_table :crm_customer_product_trackings do |t|
      t.string  :email,                    null: false, limit: 255
      t.string  :product_key,              null: false, limit: 50
      t.date    :last_order_date,          null: false
      t.string  :last_order_product_name,  null: true,  limit: 500
      t.integer :last_order_bottles,       null: false
      t.date    :expected_return_date,     null: false
      t.date    :suggested_reminder_date,  null: false
      t.integer :order_count,              null: false, default: 0
      t.integer :total_bottles,            null: false, default: 0
      t.datetime :refreshed_at,            null: false

      t.timestamps
    end

    add_index :crm_customer_product_trackings,
              [:email, :product_key],
              unique: true,
              name: "idx_crm_tracking_on_email_product"

    add_index :crm_customer_product_trackings,
              [:product_key, :expected_return_date],
              name: "idx_crm_tracking_on_product_return_date"

    add_index :crm_customer_product_trackings,
              [:product_key, :last_order_date],
              name: "idx_crm_tracking_on_product_last_order"
  end
end

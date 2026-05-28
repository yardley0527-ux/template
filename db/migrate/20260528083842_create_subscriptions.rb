class CreateSubscriptions < ActiveRecord::Migration[7.1]
  def change
    create_table :subscriptions do |t|
      t.bigint  :shopline_customer_id, null: false
      t.string  :product_name,   null: false
      t.string  :product_series
      t.integer :frequency_days, null: false
      t.decimal :discount_rate,  precision: 4, scale: 2, null: false
      t.decimal :unit_price,     precision: 10, scale: 2, null: false
      t.integer :quantity,       default: 1, null: false
      t.string  :status,         default: "active", null: false
      t.date    :started_on,     null: false
      t.date    :next_due_on,    null: false
      t.integer :completed_periods, default: 0, null: false
      t.integer :min_periods,    default: 3, null: false
      t.text    :notes

      t.timestamps
    end

    add_index :subscriptions, :shopline_customer_id
    add_index :subscriptions, :status
    add_index :subscriptions, :next_due_on
    add_index :subscriptions, :product_series
  end
end

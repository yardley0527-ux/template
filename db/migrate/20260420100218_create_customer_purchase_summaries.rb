# db/migrate/20260420000100_create_customer_purchase_summaries.rb
class CreateCustomerPurchaseSummaries < ActiveRecord::Migration[7.0]
  def change
    create_table :customer_purchase_summaries do |t|
      t.string   :email, null: false
      t.string   :first_product
      t.string   :first_series
      t.datetime :first_date
      t.decimal  :first_amount, precision: 12, scale: 2
      t.integer  :purchase_count, null: false, default: 1
      t.boolean  :silent_only, null: false, default: true
      t.timestamps
    end

    add_index :customer_purchase_summaries, :email, unique: true
    add_index :customer_purchase_summaries, :first_series
    add_index :customer_purchase_summaries, :silent_only
    add_index :customer_purchase_summaries, :first_date
    add_index :customer_purchase_summaries, :purchase_count
  end
end
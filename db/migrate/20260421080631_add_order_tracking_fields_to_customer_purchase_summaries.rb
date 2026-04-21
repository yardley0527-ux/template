# frozen_string_literal: true

class AddOrderTrackingFieldsToCustomerPurchaseSummaries < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_purchase_summaries, :first_order_number, :string
    add_column :customer_purchase_summaries, :second_order_number, :string
    add_column :customer_purchase_summaries, :second_product, :string
    add_column :customer_purchase_summaries, :second_series, :string
    add_column :customer_purchase_summaries, :second_date, :datetime
    add_column :customer_purchase_summaries, :last_order_date, :datetime
    add_column :customer_purchase_summaries, :silent_days_threshold, :integer, default: 30, null: false

    add_index :customer_purchase_summaries, :first_order_number
    add_index :customer_purchase_summaries, :second_series
    add_index :customer_purchase_summaries, :last_order_date
  end
end
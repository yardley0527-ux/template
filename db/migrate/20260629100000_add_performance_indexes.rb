class AddPerformanceIndexes < ActiveRecord::Migration[7.1]
  def change
    # customer_purchase_summaries: WHERE first_amount >= 10000 (high_spender_first_purchase)
    unless index_exists?(:customer_purchase_summaries, :first_amount, name: "index_cps_on_first_amount")
      add_index :customer_purchase_summaries, :first_amount, name: "index_cps_on_first_amount"
    end

    # Composite (first_amount, first_date) for range + threshold queries
    unless index_exists?(:customer_purchase_summaries, [:first_amount, :first_date], name: "index_cps_on_first_amount_and_first_date")
      add_index :customer_purchase_summaries, [:first_amount, :first_date], name: "index_cps_on_first_amount_and_first_date"
    end
  end
end

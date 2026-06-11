class AddFollowUpFieldsToCustomerPurchaseSummaries < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_purchase_summaries, :line_bound, :boolean, default: false, null: false
    add_column :customer_purchase_summaries, :follow_up_product, :string
  end
end

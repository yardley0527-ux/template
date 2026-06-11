class AddFollowUpWeekToCustomerPurchaseSummaries < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_purchase_summaries, :follow_up_week, :date
  end
end

class AddIndexToShoplineCustomersTotalAmount < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_index :shopline_customers, :total_amount, algorithm: :concurrently
  end
end

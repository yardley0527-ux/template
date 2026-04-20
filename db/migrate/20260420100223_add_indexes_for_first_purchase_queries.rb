# db/migrate/20260420000200_add_indexes_for_first_purchase_queries.rb
class AddIndexesForFirstPurchaseQueries < ActiveRecord::Migration[7.0]
  def change
    add_index :shopline_orders, :email unless index_exists?(:shopline_orders, :email)
    add_index :shopline_orders, [:email, :order_date] unless index_exists?(:shopline_orders, [:email, :order_date])
    add_index :shopline_orders, [:email, :order_number] unless index_exists?(:shopline_orders, [:email, :order_number])

    add_index :shopline_customers, :email unless index_exists?(:shopline_customers, :email)
  end
end
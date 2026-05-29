class AddOrderDateIndexToShoplineOrders < ActiveRecord::Migration[7.1]
  def change
    add_index :shopline_orders, :order_date,
              name: "index_shopline_orders_on_order_date"
  end
end

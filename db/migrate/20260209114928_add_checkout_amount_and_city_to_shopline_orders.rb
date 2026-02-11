# path: db/migrate/XXXXXXXXXXXXXX_add_checkout_amount_and_city_to_shopline_orders.rb
# frozen_string_literal: true

class AddCheckoutAmountAndCityToShoplineOrders < ActiveRecord::Migration[7.1]
  def change
    add_column :shopline_orders, :checkout_amount, :decimal, precision: 10, scale: 2
    add_column :shopline_orders, :city, :string

    add_index :shopline_orders, :checkout_amount
    add_index :shopline_orders, :city
  end
end

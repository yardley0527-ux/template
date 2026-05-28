class AddTrigramIndexToShoplineOrdersProductName < ActiveRecord::Migration[7.1]
  def up
    enable_extension "pg_trgm" unless extension_enabled?("pg_trgm")
    add_index :shopline_orders, :product_name,
              using: :gin,
              opclass: :gin_trgm_ops,
              name: "index_shopline_orders_on_product_name_trgm"
  end

  def down
    remove_index :shopline_orders, name: "index_shopline_orders_on_product_name_trgm"
  end
end

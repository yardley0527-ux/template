class AddUniqueIndexToShoplineCustomers < ActiveRecord::Migration[7.1]
  def change
    # 先移除舊的 non-unique index，再加 unique
    remove_index :shopline_customers, :shopline_id,
                 name: "index_shopline_customers_on_shopline_id"
    remove_index :shopline_customers, :email,
                 name: "index_shopline_customers_on_email"

    add_index :shopline_customers, :shopline_id, unique: true,
              name: "index_shopline_customers_on_shopline_id"
    add_index :shopline_customers, :email, unique: true,
              name: "index_shopline_customers_on_email",
              where: "email IS NOT NULL"  # 允許多筆 email 為 NULL
  end
end
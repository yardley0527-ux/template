class AddLookupIndexesToShoplineCustomers < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL
      CREATE INDEX index_shopline_customers_on_lower_trim_email
      ON shopline_customers (LOWER(TRIM(email)))
    SQL

    add_index :shopline_customers, :mobile_phone, name: "index_shopline_customers_on_mobile_phone"
  end

  def down
    remove_index :shopline_customers, name: "index_shopline_customers_on_mobile_phone"
    execute "DROP INDEX index_shopline_customers_on_lower_trim_email"
  end
end

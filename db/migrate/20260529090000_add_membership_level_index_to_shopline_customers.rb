class AddMembershipLevelIndexToShoplineCustomers < ActiveRecord::Migration[7.1]
  def change
    add_index :shopline_customers, :membership_level,
              name: "index_shopline_customers_on_membership_level"
  end
end

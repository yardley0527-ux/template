class AddFollowsChloeIgToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :follows_chloe_ig, :boolean, default: false, null: false
  end
end

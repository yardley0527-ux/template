class AddInvitedToFollowProductIgToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :invited_to_follow_product_ig, :boolean, default: false, null: false
  end
end

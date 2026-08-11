class AddBlackGoldFollowedUpToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :black_gold_followed_up, :boolean, default: false, null: false
  end
end

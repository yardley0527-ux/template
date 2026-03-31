class AddBrandAmbassadorBlacklistedToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :brand_ambassador_blacklisted, :boolean
  end
end

class AddHealthProfileToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :health_profile, :text
  end
end

class AddLastTrackedAtToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :last_tracked_at, :datetime
  end
end

class ReplaceLastTrackedAtWithTrackedOnCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    remove_column :customer_profiles, :last_tracked_at, :datetime
    add_column :customer_profiles, :tracked, :boolean, default: false, null: false
  end
end

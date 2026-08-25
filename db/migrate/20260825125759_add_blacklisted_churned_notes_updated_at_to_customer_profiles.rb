class AddBlacklistedChurnedNotesUpdatedAtToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :blacklisted, :boolean, default: false, null: false
    add_column :customer_profiles, :churned, :boolean, default: false, null: false
    add_column :customer_profiles, :notes_updated_at, :datetime
  end
end

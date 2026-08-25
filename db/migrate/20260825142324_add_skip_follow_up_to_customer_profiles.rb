class AddSkipFollowUpToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :skip_follow_up, :boolean, default: false, null: false
  end
end

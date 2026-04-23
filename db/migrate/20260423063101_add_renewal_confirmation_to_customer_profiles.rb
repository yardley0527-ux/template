class AddRenewalConfirmationToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :renewal_confirmed_at, :datetime
    add_column :customer_profiles, :renewal_confirmed_for, :date
  end
end

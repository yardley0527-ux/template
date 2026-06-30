class AddHealthInquiryDeclinedToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :health_inquiry_declined, :boolean, default: false, null: false
  end
end

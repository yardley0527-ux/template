class AddRecipeMessageSentToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :recipe_message_sent, :boolean, default: false, null: false
  end
end

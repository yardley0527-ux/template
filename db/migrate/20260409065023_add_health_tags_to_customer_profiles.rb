class AddHealthTagsToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :health_tags, :string, array: true, default: [], null: false
    add_index :customer_profiles, :health_tags, using: :gin
  end
end

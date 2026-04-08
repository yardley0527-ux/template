class AddProfileFieldsToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :feedback, :text
    add_column :customer_profiles, :special_attention, :text
    add_column :customer_profiles, :product_tags, :string, array: true, default: [], null: false

    add_index :customer_profiles, :product_tags, using: :gin
  end
end
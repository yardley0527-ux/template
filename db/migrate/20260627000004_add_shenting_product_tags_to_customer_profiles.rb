class AddShentingProductTagsToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :customer_profiles, :shengting_product_tags, :string, array: true, default: [], null: false
    add_index :customer_profiles, :shengting_product_tags, using: :gin
  end
end

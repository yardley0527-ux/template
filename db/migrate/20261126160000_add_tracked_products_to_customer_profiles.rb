class AddTrackedProductsToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    # 待追蹤的產品：只有 tracked=true 時有值
    add_column :customer_profiles, :tracked_products, :string, array: true, default: [], null: false
  end
end

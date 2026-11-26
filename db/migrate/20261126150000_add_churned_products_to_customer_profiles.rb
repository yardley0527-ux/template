class AddChurnedProductsToCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    # 已流失的產品：空陣列＋churned=true 代表整個客人流失；有值代表只有這幾樣產品流失
    add_column :customer_profiles, :churned_products, :string, array: true, default: [], null: false
  end
end

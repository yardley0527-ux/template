class CreateCustomerProfiles < ActiveRecord::Migration[7.1]
  def change
    create_table :customer_profiles do |t|
      t.integer :shopline_customer_id
      t.boolean :brand_ambassador_training
      t.text :notes

      t.timestamps
    end
    add_index :customer_profiles, :shopline_customer_id
  end
end

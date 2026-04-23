class AddIdentityKeyToCustomerPurchaseSummaries < ActiveRecord::Migration[7.1]
  def up
    add_column :customer_purchase_summaries, :mobile_phone, :string
    add_column :customer_purchase_summaries, :identity_key, :string

    execute "UPDATE customer_purchase_summaries SET identity_key = email"

    change_column_null :customer_purchase_summaries, :identity_key, false

    remove_index :customer_purchase_summaries, :email, if_exists: true
    add_index :customer_purchase_summaries, :identity_key, unique: true
    add_index :customer_purchase_summaries, :mobile_phone
    add_index :customer_purchase_summaries, :email
  end

  def down
    remove_index :customer_purchase_summaries, :identity_key, if_exists: true
    remove_index :customer_purchase_summaries, :mobile_phone, if_exists: true
    remove_index :customer_purchase_summaries, :email, if_exists: true

    add_index :customer_purchase_summaries, :email, unique: true

    remove_column :customer_purchase_summaries, :identity_key
    remove_column :customer_purchase_summaries, :mobile_phone
  end
end

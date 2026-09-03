class CreateGroupBuyContacts < ActiveRecord::Migration[7.1]
  def change
    create_table :group_buy_contacts do |t|
      t.string :brand_name, null: false
      t.string :product
      t.string :channel
      t.string :contact_handle
      t.date :contacted_on
      t.string :status, null: false, default: "待回覆"
      t.date :follow_up_on
      t.text :notes

      t.timestamps
    end

    add_index :group_buy_contacts, :status
    add_index :group_buy_contacts, :contacted_on
  end
end

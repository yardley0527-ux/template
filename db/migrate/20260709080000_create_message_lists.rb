class CreateMessageLists < ActiveRecord::Migration[7.1]
  def change
    create_table :message_lists do |t|
      t.string :name, null: false
      t.date :sent_on, null: false
      t.string :target_product, null: false
      t.text :source_note
      t.timestamps
    end

    create_table :message_list_recipients do |t|
      t.references :message_list, null: false, foreign_key: true
      t.string :email, null: false
      t.string :full_name
      t.string :instagram_account
      t.string :membership_level
      t.bigint :shopline_customer_id
      t.timestamps
    end

    add_index :message_list_recipients, [:message_list_id, :email], unique: true
  end
end

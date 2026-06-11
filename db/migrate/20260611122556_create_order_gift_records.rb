class CreateOrderGiftRecords < ActiveRecord::Migration[7.1]
  def change
    create_table :order_gift_records do |t|
      t.string :order_number
      t.boolean :gift_sent, default: false, null: false
      t.string :gift_note
      t.string :updated_by

      t.timestamps
    end
    add_index :order_gift_records, :order_number, unique: true
  end
end

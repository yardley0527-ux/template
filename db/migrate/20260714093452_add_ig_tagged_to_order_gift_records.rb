class AddIgTaggedToOrderGiftRecords < ActiveRecord::Migration[7.1]
  def change
    add_column :order_gift_records, :ig_tagged, :boolean, default: false, null: false
  end
end

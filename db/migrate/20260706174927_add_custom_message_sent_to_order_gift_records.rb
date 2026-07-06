class AddCustomMessageSentToOrderGiftRecords < ActiveRecord::Migration[7.1]
  def change
    add_column :order_gift_records, :custom_message_sent, :boolean, default: false, null: false
  end
end

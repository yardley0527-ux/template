class AddHealthCardSentToOrderGiftRecords < ActiveRecord::Migration[7.1]
  def change
    add_column :order_gift_records, :health_card_sent, :boolean, default: false, null: false
  end
end

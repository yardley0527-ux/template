class AddFollowUpNoteToOrderGiftRecords < ActiveRecord::Migration[7.1]
  def change
    add_column :order_gift_records, :follow_up_note, :text
  end
end

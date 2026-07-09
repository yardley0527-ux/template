class AddFollowedUpAtToOrderGiftRecords < ActiveRecord::Migration[7.1]
  def up
    add_column :order_gift_records, :followed_up_at, :datetime
    # 既有已填備註的紀錄，以最後更新時間近似追蹤時間
    execute <<~SQL
      UPDATE order_gift_records
      SET followed_up_at = updated_at
      WHERE follow_up_note IS NOT NULL AND follow_up_note <> ''
    SQL
  end

  def down
    remove_column :order_gift_records, :followed_up_at
  end
end

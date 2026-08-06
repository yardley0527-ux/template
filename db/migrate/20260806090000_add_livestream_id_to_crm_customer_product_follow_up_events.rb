class AddLivestreamIdToCrmCustomerProductFollowUpEvents < ActiveRecord::Migration[7.1]
  def change
    # 讓一筆客服操作紀錄可以標記「屬於哪一場直播的候選名單操作」，nullable——
    # 一般回購 Dashboard 操作（非直播名單）不會有這個值。
    add_column :crm_customer_product_follow_up_events, :livestream_id, :bigint
    add_index :crm_customer_product_follow_up_events, :livestream_id
    add_foreign_key :crm_customer_product_follow_up_events, :livestreams, column: :livestream_id
  end
end

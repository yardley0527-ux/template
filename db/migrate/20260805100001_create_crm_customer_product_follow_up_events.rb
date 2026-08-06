class CreateCrmCustomerProductFollowUpEvents < ActiveRecord::Migration[7.1]
  def change
    # 每次客服操作的完整歷史紀錄，cycle 上的 follow_up_status/last_contacted_at/
    # next_contact_date/assigned_to_user_id 只保留「目前狀態」供列表快速查詢，
    # 不覆蓋掉這張表——歷史永遠可回溯是誰、何時、做了什麼判斷。
    create_table :crm_customer_product_follow_up_events do |t|
      t.bigint   :cycle_id,              null: false
      t.bigint   :performed_by_user_id,  null: false
      t.string   :action,                null: false
      t.text     :note
      t.date     :next_contact_date
      # 只有 action = repurchased 時才有意義：記錄「當下」cycle 的
      # next_same_product_order_number 快照（系統已偵測到的訂單號)。
      # nil 代表當下沒有系統偵測到的訂單，是純人工確認——這欄位只複製
      # 既有真實值，不可能被用來偽造一筆不存在的訂單。
      t.string   :detected_order_number
      t.datetime :performed_at,          null: false

      t.timestamps
    end

    add_index :crm_customer_product_follow_up_events, :cycle_id
    add_index :crm_customer_product_follow_up_events, [:cycle_id, :performed_at]
    add_index :crm_customer_product_follow_up_events, :performed_by_user_id

    add_foreign_key :crm_customer_product_follow_up_events, :crm_customer_product_cycles, column: :cycle_id
    add_foreign_key :crm_customer_product_follow_up_events, :users, column: :performed_by_user_id
  end
end

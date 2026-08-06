class AddFollowUpFieldsToCrmCustomerProductCycles < ActiveRecord::Migration[7.1]
  def change
    # follow_up_status 是人工狀態（waiting_reply/rescheduled/paused/repurchased），
    # nil 代表「還沒有人工介入」，此時 due_today/due_soon/overdue 用日期即時算，
    # 不重複存欄位（Phase 2 規格：日期型狀態能即時計算就不要落地）。
    add_column :crm_customer_product_cycles, :follow_up_status, :string
    add_column :crm_customer_product_cycles, :last_contacted_at, :datetime
    add_column :crm_customer_product_cycles, :next_contact_date, :date
    add_column :crm_customer_product_cycles, :assigned_to_user_id, :bigint

    add_index :crm_customer_product_cycles, :follow_up_status
    add_index :crm_customer_product_cycles, :assigned_to_user_id
    add_index :crm_customer_product_cycles, :next_contact_date

    add_foreign_key :crm_customer_product_cycles, :users, column: :assigned_to_user_id
  end
end

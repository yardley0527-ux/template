class AddCrmMaintenanceUnreadToOrderGiftRecords < ActiveRecord::Migration[7.1]
  def change
    add_column :order_gift_records, :crm_maintenance_unread, :boolean, default: false, null: false
  end
end

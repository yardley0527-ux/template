class AddProductKeyToOmnipotentNotificationStatuses < ActiveRecord::Migration[7.1]
  def change
    add_column :omnipotent_notification_statuses, :product_key, :string, default: "omnipotent", null: false
    add_index  :omnipotent_notification_statuses, [:email, :reference_date, :product_key],
               unique: true, name: "idx_omni_notif_status_unique"
  end
end

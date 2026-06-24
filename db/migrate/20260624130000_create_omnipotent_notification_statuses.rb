class CreateOmnipotentNotificationStatuses < ActiveRecord::Migration[7.1]
  def change
    create_table :omnipotent_notification_statuses do |t|
      t.string   :email,          null: false
      t.date     :reference_date, null: false  # 對應的購買日，回購後自動開新旅程
      t.string   :status,         null: false, default: "未通知"
      t.datetime :notified_at
      t.text     :note
      t.timestamps
    end
    add_index :omnipotent_notification_statuses, [:email, :reference_date], unique: true, name: "idx_omni_notif_email_date"
    add_index :omnipotent_notification_statuses, :status
  end
end

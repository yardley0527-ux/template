class AddContactDetailsToOmnipotentNotificationStatuses < ActiveRecord::Migration[7.1]
  def change
    add_column :omnipotent_notification_statuses, :channel,      :string
    add_column :omnipotent_notification_statuses, :result,       :string
    add_column :omnipotent_notification_statuses, :contacted_at, :date
  end
end

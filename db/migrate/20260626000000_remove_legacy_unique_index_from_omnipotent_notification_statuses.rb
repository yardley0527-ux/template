class RemoveLegacyUniqueIndexFromOmnipotentNotificationStatuses < ActiveRecord::Migration[7.1]
  def up
    if index_exists?(:omnipotent_notification_statuses, [:email, :reference_date], name: "idx_omni_notif_email_date")
      remove_index :omnipotent_notification_statuses, name: "idx_omni_notif_email_date"
    end
  end

  def down
    unless index_exists?(:omnipotent_notification_statuses, [:email, :reference_date], name: "idx_omni_notif_email_date")
      add_index :omnipotent_notification_statuses, [:email, :reference_date],
                 unique: true, name: "idx_omni_notif_email_date"
    end
  end
end

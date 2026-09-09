class ReplaceFollowUpFlagsWithMaintenanceLogOnMessageListRecipients < ActiveRecord::Migration[7.1]
  def change
    remove_column :message_list_recipients, :maintained, :boolean, default: false, null: false
    remove_column :message_list_recipients, :follow_up_needed, :boolean, default: false, null: false

    add_column :message_list_recipients, :maintenance_date, :date
    add_column :message_list_recipients, :content_usage_status, :boolean, default: false, null: false
    add_column :message_list_recipients, :content_restock_reminder, :boolean, default: false, null: false
    add_column :message_list_recipients, :content_product_education, :boolean, default: false, null: false
    add_column :message_list_recipients, :content_promotion_notice, :boolean, default: false, null: false
    add_column :message_list_recipients, :content_upgrade_reminder, :boolean, default: false, null: false
    add_column :message_list_recipients, :customer_status, :string
    add_column :message_list_recipients, :next_follow_up_date, :date
  end
end

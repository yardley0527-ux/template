class AddFollowUpFlagsToMessageListRecipients < ActiveRecord::Migration[7.1]
  def change
    add_column :message_list_recipients, :maintained, :boolean, default: false, null: false
    add_column :message_list_recipients, :follow_up_needed, :boolean, default: false, null: false
  end
end

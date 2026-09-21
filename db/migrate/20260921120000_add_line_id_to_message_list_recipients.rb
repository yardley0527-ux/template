class AddLineIdToMessageListRecipients < ActiveRecord::Migration[7.1]
  def change
    add_column :message_list_recipients, :line_id, :string
  end
end

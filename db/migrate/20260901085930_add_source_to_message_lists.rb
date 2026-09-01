class AddSourceToMessageLists < ActiveRecord::Migration[7.1]
  def change
    add_column :message_lists, :source, :string, default: "manual", null: false
  end
end

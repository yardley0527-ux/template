# frozen_string_literal: true

class AddMessageContentToMessageLists < ActiveRecord::Migration[7.1]
  def change
    add_column :message_lists, :message_content, :text
  end
end

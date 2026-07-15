# frozen_string_literal: true

class AddSegmentToMessageListRecipients < ActiveRecord::Migration[7.1]
  def change
    # if_not_exists：正式站為了即時標示已先用 psql 加欄，部署跑到這裡時直接略過
    add_column :message_list_recipients, :segment, :string, if_not_exists: true
  end
end

# frozen_string_literal: true

class AddPurchasedOnToMessageListRecipients < ActiveRecord::Migration[7.1]
  def change
    add_column :message_list_recipients, :purchased_on, :date
  end
end

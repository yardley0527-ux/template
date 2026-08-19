class AddEmailSentToKocsAndReloveKocs < ActiveRecord::Migration[7.1]
  def change
    add_column :kocs, :email_sent, :boolean, default: false, null: false
    add_column :relove_kocs, :email_sent, :boolean, default: false, null: false
  end
end

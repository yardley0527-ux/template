class AddMessageStatsToDailyMemberStats < ActiveRecord::Migration[7.1]
  def change
    add_column :daily_member_stats, :api_push,  :integer
    add_column :daily_member_stats, :api_reply, :integer
  end
end

# 記錄上次寫回 ManyChat 自訂欄位的內容摘要，沒變就不重打 API。
class AddFieldSyncToManychatSubscribers < ActiveRecord::Migration[7.1]
  def change
    add_column :manychat_subscribers, :fields_digest, :string
    add_column :manychat_subscribers, :fields_synced_at, :datetime
  end
end

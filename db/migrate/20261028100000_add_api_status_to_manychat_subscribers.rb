# ManyChat API（subscriber/getInfo）查到的狀態，補試算表沒寫到的互動用（見 Manychat::InteractionBackfill）。
# status：active＝有互動過、visitor＝只是被加進來（如新追蹤）沒互動；source＝「來源」自訂欄位目前的值。
# sheet_rows：上次同步時試算表裡這個人有幾列，變多代表有新互動，要再用 API 查一次（api_checked_at 清空）。
class AddApiStatusToManychatSubscribers < ActiveRecord::Migration[7.1]
  def change
    add_column :manychat_subscribers, :status, :string
    add_column :manychat_subscribers, :subscribed_at, :datetime
    add_column :manychat_subscribers, :source, :string
    add_column :manychat_subscribers, :sheet_rows, :integer, null: false, default: 0
    add_column :manychat_subscribers, :api_checked_at, :datetime
  end
end

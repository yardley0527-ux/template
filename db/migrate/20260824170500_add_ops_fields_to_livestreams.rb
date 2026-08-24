# 直播營運監控用的最小必要欄位——先確認過 livestreams 沒有現成欄位可以表示
# 「這場直播的負責人是誰」跟「賽後檢討是否已完成」，兩者都無法從既有資料
# （shopline_orders／livestream_products／CalendarEvent）推導出來，必須落地保存。
# 檢討報告本身仍是外部 Claude Artifact 連結（LivestreamReportsController::REPORTS，
# 寫死在程式碼裡），這裡不重造一套報告內容儲存，只加「是否已完成」的旗標讓
# livestream_review_due 規則可以判斷、解除。
class AddOpsFieldsToLivestreams < ActiveRecord::Migration[7.1]
  def change
    add_column :livestreams, :owner_user_id, :bigint
    add_column :livestreams, :review_completed_at, :datetime
    add_column :livestreams, :review_completed_by_user_id, :bigint

    add_index :livestreams, :owner_user_id
    add_foreign_key :livestreams, :users, column: :owner_user_id
    add_foreign_key :livestreams, :users, column: :review_completed_by_user_id
  end
end

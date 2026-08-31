# 廣告測試直播跟正式（有真實訂單歸因）的直播性質不同，改成獨立的
# LiveAdTest model（見 CreateLiveAdTests），這裡把先前加到 livestreams
# 的欄位移除，避免兩套資料混在同一張表。
class RemoveLiveAdsFieldsFromLivestreams < ActiveRecord::Migration[7.1]
  def change
    remove_index :livestreams, :platform

    remove_column :livestreams, :platform, :string
    remove_column :livestreams, :link_keyword, :string
    remove_column :livestreams, :start_time, :string
    remove_column :livestreams, :end_time, :string
    remove_column :livestreams, :ran_ads, :boolean, default: false, null: false
    remove_column :livestreams, :ad_approved_time, :string
    remove_column :livestreams, :ad_spend, :decimal, precision: 12, scale: 2, default: "0.0", null: false
    remove_column :livestreams, :viewers_entry, :integer
    remove_column :livestreams, :viewers_peak, :integer
    remove_column :livestreams, :viewers_end, :integer
  end
end

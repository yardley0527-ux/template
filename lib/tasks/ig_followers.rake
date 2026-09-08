namespace :ig_followers do
  desc "一次性：把 data/ig_followers_data.json 的歷史資料匯入 ig_follower_snapshots 資料表（本機用；正式站會在第一次載入頁面時自動做）"
  task backfill: :environment do
    imported = IgFollowerSnapshot.backfill_from_json!
    puts "匯入完成：#{imported} 筆寫入。"
  end
end

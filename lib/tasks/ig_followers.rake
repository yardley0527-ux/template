namespace :ig_followers do
  desc "一次性：把 data/ig_followers_data.json 的歷史資料匯入 ig_follower_snapshots 資料表"
  task backfill: :environment do
    path = Rails.root.join("data", "ig_followers_data.json")
    unless File.exist?(path)
      puts "找不到 #{path}，沒有東西可以匯入。"
      next
    end

    data = JSON.parse(File.read(path))
    imported = 0
    skipped = 0

    data.each do |account, entries|
      entries.each do |entry|
        date = Date.parse(entry["date"])
        followers = entry["followers"]
        next if followers.nil?

        record = IgFollowerSnapshot.find_or_initialize_by(account: account, snapshot_date: date)
        record.followers = followers
        if record.save
          imported += 1
        else
          skipped += 1
          puts "  跳過 #{account} #{date}：#{record.errors.full_messages.join(', ')}"
        end
      end
    end

    puts "匯入完成：#{imported} 筆寫入，#{skipped} 筆跳過。"
  end
end

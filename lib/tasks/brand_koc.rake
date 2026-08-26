require "csv"

# 通用版的 koc.rake / relove_koc.rake——新品牌業配名單只需要一個 model + 一份
# CSV，不用每個品牌各寫一份幾乎一樣的匯入邏輯。CSV 欄位跟既有兩份完全同格式
# （ownerUsername/ownerFullName/ownerId/likesCount/videoPlayCount/igPlayCount/
# timestamp/paidPartnership/url），因為都是同一個 Apify actor
# apify/instagram-tagged-scraper 撈出來的（見 rake ig_tagged:fetch）。
namespace :brand_koc do
  desc "Import a brand KOC list from data/koc_sources/<csv_filename>. Usage: rake \"brand_koc:import[BodyGoalsKoc,body_goals_ig_mentions.csv,Body Goals]\""
  task :import, [:model_class, :csv_filename, :brand_label] => :environment do |_, args|
    model = args[:model_class].constantize
    scrape_path = Rails.root.join("data", "koc_sources", args[:csv_filename])

    unless File.exist?(scrape_path)
      puts "找不到 IG 標記資料：#{scrape_path}"
      next
    end

    stats_by_username = {}

    CSV.foreach(scrape_path, headers: true) do |row|
      username = row["ownerUsername"].to_s.strip
      next if username.blank?

      likes = row["likesCount"].to_i
      likes = nil if likes.negative?
      video_views = [row["videoPlayCount"].to_i, row["igPlayCount"].to_i].max
      timestamp = begin
        Time.zone.parse(row["timestamp"])
      rescue StandardError
        nil
      end
      paid = row["paidPartnership"].to_s.strip.downcase == "true"

      entry = stats_by_username[username] ||= {
        ig_full_name: nil, ig_user_id: nil, post_count: 0,
        max_likes: nil, max_video_views: 0, has_paid_partnership: false,
        last_post_at: nil, last_post_url: nil
      }

      entry[:ig_full_name] = row["ownerFullName"].presence || entry[:ig_full_name]
      entry[:ig_user_id] = row["ownerId"].presence || entry[:ig_user_id]
      entry[:post_count] += 1
      entry[:max_likes] = [entry[:max_likes] || 0, likes || 0].max if likes
      entry[:max_video_views] = [entry[:max_video_views], video_views].max
      entry[:has_paid_partnership] ||= paid

      if timestamp && (entry[:last_post_at].nil? || timestamp > entry[:last_post_at])
        entry[:last_post_at] = timestamp
        entry[:last_post_url] = row["url"]
      end
    end

    created = 0
    updated = 0

    stats_by_username.each do |username, stats|
      koc = model.find_or_initialize_by(ig_username: username)
      is_new = koc.new_record?

      koc.ig_full_name = stats[:ig_full_name]
      koc.ig_user_id = stats[:ig_user_id]
      koc.post_count = stats[:post_count]
      koc.max_likes = stats[:max_likes]
      koc.max_video_views = stats[:max_video_views]
      koc.has_paid_partnership = stats[:has_paid_partnership]
      koc.last_post_at = stats[:last_post_at]
      koc.last_post_url = stats[:last_post_url]
      koc.source = "IG標記偵測（#{args[:brand_label]}）"
      koc.save!

      is_new ? created += 1 : updated += 1
    end

    puts "匯入完成：新增 #{created} 筆，更新 #{updated} 筆，總計 #{model.count} 筆 #{args[:brand_label]} KOC。"
  end
end

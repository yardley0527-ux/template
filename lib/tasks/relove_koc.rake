require "csv"

namespace :relove_koc do
  desc "Import Relove KOC reference list from data/koc_sources (IG mention scrape)"
  task import: :environment do
    scrape_path = Rails.root.join("data", "koc_sources", "relove_ig_mentions_2026-06-20.csv")

    stats_by_username = {}

    if File.exist?(scrape_path)
      CSV.foreach(scrape_path, headers: true) do |row|
        username = row["ownerUsername"].to_s.strip
        next if username.blank?

        likes = row["likesCount"].to_i
        likes = nil if likes.negative?
        video_views = [row["videoPlayCount"].to_i, row["igPlayCount"].to_i].max
        timestamp = Time.zone.parse(row["timestamp"]) rescue nil
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
    else
      puts "找不到 IG 標記資料：#{scrape_path}"
    end

    created = 0
    updated = 0

    stats_by_username.each do |username, stats|
      koc = ReloveKoc.find_or_initialize_by(ig_username: username)
      is_new = koc.new_record?

      koc.ig_full_name = stats[:ig_full_name]
      koc.ig_user_id = stats[:ig_user_id]
      koc.post_count = stats[:post_count]
      koc.max_likes = stats[:max_likes]
      koc.max_video_views = stats[:max_video_views]
      koc.has_paid_partnership = stats[:has_paid_partnership]
      koc.last_post_at = stats[:last_post_at]
      koc.last_post_url = stats[:last_post_url]
      koc.source = "IG標記偵測（relove）"
      koc.save!

      is_new ? created += 1 : updated += 1
    end

    puts "匯入完成：新增 #{created} 筆，更新 #{updated} 筆，總計 #{ReloveKoc.count} 筆 Relove KOC。"
  end
end

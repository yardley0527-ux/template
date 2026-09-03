# path: app/services/kol_ig_metrics_fetcher.rb
# frozen_string_literal: true

require "net/http"
require "json"

# 幫 KolCandidate 撈 Instagram 帳號數據＋近期貼文互動率，寫成一筆 KolMetricSnapshot。
# 跟既有的 IgScraperService（服務 IgProfile/IgPost，供 IG 受眾重疊分析等功能用）是
# 兩條獨立管線，故意不共用資料表——業配評估這邊只需要「這個人現在數據好不好」的
# 快照，不需要 IgScraperService 那套逐篇貼文長期累積的資料模型。
class KolIgMetricsFetcher
  ACTOR_ID = "apify~instagram-profile-scraper"

  def self.fetch(candidate)
    new(candidate).call
  end

  def initialize(candidate)
    @candidate = candidate
  end

  def call
    return false if @candidate.instagram_handle.blank?

    item = fetch_from_apify
    return false if item.nil?

    posts = item.fetch("latestPosts", [])
    likes = posts.map { |p| p["likesCount"].to_i }
    comments = posts.map { |p| p["commentsCount"].to_i }
    views = posts.filter_map { |p| p["videoViewCount"] }
    followers = item["followersCount"].to_i

    avg_likes = likes.empty? ? nil : likes.sum / likes.size
    avg_comments = comments.empty? ? 0 : comments.sum / comments.size
    avg_views = views.empty? ? nil : views.sum / views.size
    engagement_rate = (followers.positive? && avg_likes) ? ((avg_likes + avg_comments).to_f / followers * 100).round(3) : nil

    @candidate.kol_metric_snapshots.create!(
      platform: "instagram",
      followers_count: followers,
      following_count: item["followsCount"].to_i,
      posts_count: item["postsCount"].to_i,
      engagement_rate: engagement_rate,
      avg_views: avg_views,
      avg_likes: avg_likes,
      source: "apify",
      fetched_at: Time.current,
      raw_data: {
        avg_comments: avg_comments,
        sample_size: posts.size,
        verified: item["verified"],
        business_category: item["businessCategoryName"],
        recent_posts: posts.first(12).map { |p| p.slice("shortCode", "likesCount", "commentsCount", "videoViewCount", "timestamp") },
      }
    )
    true
  rescue => e
    Rails.logger.error("[KolIgMetricsFetcher] #{e.class}: #{e.message}")
    false
  end

  private

  def fetch_from_apify
    token = ENV["APIFY_API_KEY"].presence || ENV["APIFY_TOKEN"].presence
    return nil if token.blank?

    uri = URI("https://api.apify.com/v2/acts/#{ACTOR_ID}/run-sync-get-dataset-items")
    uri.query = URI.encode_www_form(token: token, timeout: 120)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 150

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = { usernames: [@candidate.instagram_handle] }.to_json

    response = http.request(request)
    items = JSON.parse(response.body.dup.force_encoding("UTF-8"))
    items.first
  end
end

require 'net/http'
require 'json'

class ThreadsScraperService
  ACTOR_ID    = "automation-lab~threads-scraper"
  APIFY_TOKEN = ENV['APIFY_TOKEN']

  KEYWORDS = %w[
    益生菌 膠原蛋白 保健食品 美白 抗老化
    魚油 薑黃 代謝 腸道健康 穀胱甘肽 蔓越莓 眼睛保健
  ].freeze

  def self.run
    new.call
  end

  def call
    items = fetch_from_apify
    return false if items.empty?

    today = Date.today
    saved = 0

    items.each do |item|
      post_id = item["postId"].presence || item["code"].presence
      next if post_id.blank?

      ThreadsPost.find_or_initialize_by(post_id: post_id).tap do |p|
        p.username     = item["username"]
        p.full_name    = item["fullName"]
        p.text_content = item["text"].to_s.slice(0, 500)
        p.like_count   = item["likeCount"].to_i
        p.reply_count  = item["replyCount"].to_i
        p.repost_count = item["repostCount"].to_i
        p.post_url     = item["url"]
        p.keyword      = detect_keyword(item["text"].to_s)
        p.posted_at    = parse_time(item["timestamp"] || item["date"])
        p.fetched_on   = today
        p.save!
        saved += 1
      end
    end

    Rails.logger.info("[ThreadsScraperService] Saved #{saved} posts")
    true
  rescue => e
    Rails.logger.error("[ThreadsScraperService] #{e.class}: #{e.message}")
    false
  end

  private

  def fetch_from_apify
    uri = URI("https://api.apify.com/v2/acts/#{ACTOR_ID}/run-sync-get-dataset-items")
    uri.query = URI.encode_www_form(token: APIFY_TOKEN, timeout: 180)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl    = true
    http.read_timeout = 210

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = {
      mode: "search",
      searchQueries: KEYWORDS,
      maxPosts: 15
    }.to_json

    response = http.request(request)
    JSON.parse(response.body)
  end

  def detect_keyword(text)
    KEYWORDS.find { |kw| text.include?(kw) } || KEYWORDS.first
  end

  def parse_time(raw)
    return nil if raw.blank?
    Time.parse(raw.to_s)
  rescue
    nil
  end
end

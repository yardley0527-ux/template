require 'net/http'
require 'json'

class ThreadsScraperService
  API_BASE = "https://api.scrapecreators.com/v1/threads/search"
  API_KEY  = ENV['SCRAPECREATORS_API_KEY']

  KEYWORDS = %w[
    益生菌 膠原蛋白 保健食品 美白 抗老化
    魚油 薑黃 代謝 腸道健康 穀胱甘肽 蔓越莓 眼睛保健
    probiotics collagen supplement
  ].freeze

  def self.run
    new.call
  end

  def call
    if API_KEY.blank?
      Rails.logger.error("[ThreadsScraperService] SCRAPECREATORS_API_KEY 未設定")
      return false
    end

    today = Date.today
    saved = 0

    KEYWORDS.each do |keyword|
      posts = fetch_keyword(keyword)
      posts.each do |item|
        post_id = item["pk"].to_s.presence || item["id"].to_s.presence
        next if post_id.blank?

        username = item.dig("user", "username")
        code     = item["code"]

        ThreadsPost.find_or_initialize_by(post_id: post_id).tap do |p|
          p.username     = username
          p.full_name    = item.dig("user", "full_name").to_s.presence || username
          p.text_content = item.dig("caption", "text").to_s.slice(0, 500)
          p.like_count   = item["like_count"].to_i
          p.reply_count  = item.dig("text_post_app_info", "direct_reply_count").to_i
          p.repost_count = item.dig("text_post_app_info", "repost_count").to_i
          p.post_url     = code.present? && username.present? ? "https://www.threads.net/@#{username}/post/#{code}" : nil
          p.keyword      = keyword
          p.posted_at    = parse_time(item["taken_at"])
          p.fetched_on   = today
          p.save!
          saved += 1
        end
      rescue => e
        Rails.logger.warn("[ThreadsScraperService] skip post: #{e.message}")
      end
    end

    Rails.logger.info("[ThreadsScraperService] Saved #{saved} posts")
    true
  rescue => e
    Rails.logger.error("[ThreadsScraperService] #{e.class}: #{e.message}")
    false
  end

  private

  def fetch_keyword(keyword)
    uri = URI(API_BASE)
    uri.query = URI.encode_www_form(query: keyword)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.read_timeout = 30

    request = Net::HTTP::Get.new(uri)
    request["x-api-key"] = API_KEY

    response = http.request(request)
    body = JSON.parse(response.body)

    posts = body["posts"] || []
    Rails.logger.info("[ThreadsScraperService] keyword=#{keyword} status=#{response.code} posts=#{posts.size} raw=#{response.body.to_s.first(200)}")
    posts
  rescue => e
    Rails.logger.warn("[ThreadsScraperService] keyword=#{keyword} error: #{e.message}")
    []
  end

  def parse_time(raw)
    return nil if raw.blank?
    raw.is_a?(Integer) ? Time.at(raw) : Time.parse(raw.to_s)
  rescue
    nil
  end
end

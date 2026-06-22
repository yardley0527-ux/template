require 'net/http'
require 'json'

class ThreadsScraperService
  API_BASE = "https://api.apify.com/v2/acts/automation-lab~threads-scraper/run-sync-get-dataset-items"
  API_KEY  = ENV['APIFY_API_KEY']
  MAX_POSTS_PER_KEYWORD = 20

  KEYWORD_CATEGORIES = {
    "代謝瘦身" => %w[代謝 減肥 瘦身 燃脂 體脂 減脂 水腫],
    "腸道排便" => %w[益生菌 腸道健康 便秘 排便 脹氣],
    "美白抗老" => %w[美白 穀胱甘肽 膠原蛋白 NMN 白藜蘆醇],
    "私密保養" => %w[蔓越莓 私密處 泌尿道],
    "眼睛保健" => %w[眼睛保健 蝦紅素 花青素],
    "肝臟護肝" => %w[薑黃 護肝],
    "魚油心血管" => %w[魚油 發炎],
    "睡眠疲勞" => %w[失眠 疲勞 B群 落髮 髮際線],
    "皮膚保養" => %w[痘痘 敏感肌 暗沉 面膜],
    "骨骼保健" => %w[骨質疏鬆 鈣],
  }.freeze

  KEYWORDS = KEYWORD_CATEGORIES.values.flatten.freeze

  def self.run
    new.call
  end

  def call
    if API_KEY.blank?
      Rails.logger.error("[ThreadsScraperService] APIFY_API_KEY 未設定")
      return false
    end

    today = Date.today
    saved = 0

    KEYWORDS.each do |keyword|
      posts = fetch_keyword(keyword)
      posts.each do |item|
        post_id = item["postId"].to_s
        next if post_id.blank?

        username = item["username"]
        code     = item["code"]

        text = item["text"].to_s
        next unless text.include?(keyword)

        ThreadsPost.find_or_initialize_by(post_id: post_id).tap do |p|
          p.username     = username
          p.full_name    = item["fullName"].to_s.presence || username
          p.text_content = text.slice(0, 500)
          p.like_count   = item["likeCount"].to_i
          p.reply_count  = item["replyCount"].to_i
          p.repost_count = item["repostCount"].to_i
          p.post_url     = item["url"].presence || (code.present? && username.present? ? "https://www.threads.net/@#{username}/post/#{code}" : nil)
          p.keyword      = keyword
          p.posted_at    = parse_time(item["date"] || item["timestamp"])
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
    uri.query = URI.encode_www_form(token: API_KEY)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.read_timeout = 120

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = { mode: "search", searchQueries: [keyword], maxPosts: MAX_POSTS_PER_KEYWORD }.to_json

    response = http.request(request)
    posts = JSON.parse(response.body)
    posts = [] unless posts.is_a?(Array)

    Rails.logger.info("[ThreadsScraperService] keyword=#{keyword} status=#{response.code} posts=#{posts.size}")
    posts
  rescue => e
    Rails.logger.warn("[ThreadsScraperService] keyword=#{keyword} error: #{e.message}")
    []
  end

  def parse_time(raw)
    return nil if raw.blank?
    raw.is_a?(Numeric) ? Time.at(raw) : Time.parse(raw.to_s)
  rescue
    nil
  end
end

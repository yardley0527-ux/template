require 'net/http'
require 'json'

class IgScraperService
  ACTOR_ID    = "apify~instagram-profile-scraper"
  APIFY_TOKEN = ENV['APIFY_TOKEN']

  def self.scrape(username)
    new(username).call
  end

  def initialize(username)
    @username = username
  end

  def call
    items = fetch_from_apify
    return false if items.empty?

    item = items.first
    profile = find_or_create_profile(item)
    save_snapshot(profile)
    save_posts(profile, item.fetch("latestPosts", []))
    true
  rescue => e
    Rails.logger.error("[IgScraperService] #{e.class}: #{e.message}")
    false
  end

  private

  def fetch_from_apify
    uri = URI("https://api.apify.com/v2/acts/#{ACTOR_ID}/run-sync-get-dataset-items")
    uri.query = URI.encode_www_form(token: APIFY_TOKEN, timeout: 120)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 150

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = { usernames: [@username] }.to_json

    response = http.request(request)
    JSON.parse(response.body)
  end

  def find_or_create_profile(item)
    profile = IgProfile.find_or_initialize_by(username: @username)
    profile.assign_attributes(
      display_name:   item["fullName"].presence || item["full_name"].presence,
      bio:            item["biography"].presence || item["bio"].presence,
      follower_count: item["followersCount"].to_i,
      following_count: item["followsCount"].to_i,
      post_count:     item["postsCount"].to_i,
      profile_pic_url: item["profilePicUrl"].presence || item["profile_pic_url"].presence,
      external_url:   item["externalUrl"].presence,
      is_verified:    item["verified"] || item["isVerified"] || false,
      last_scraped_at: Time.current,
    )
    profile.save!
    profile
  end

  def save_snapshot(profile)
    today = Date.today
    IgSnapshot.find_or_create_by(ig_profile: profile, snapshot_date: today) do |s|
      s.follower_count = profile.follower_count
      s.post_count     = profile.post_count
    end
  end

  def save_posts(profile, posts)
    posts.each do |post|
      shortcode = post["shortCode"].presence || post["id"].to_s
      next if shortcode.blank?

      posted_at = begin
        raw = post["timestamp"] || post["takenAtTimestamp"]
        raw.present? ? Time.parse(raw.to_s) : nil
      rescue
        nil
      end

      IgPost.find_or_initialize_by(shortcode: shortcode).tap do |p|
        p.ig_profile = profile
        p.caption    = post["caption"].to_s.slice(0, 500)
        p.likes      = post["likesCount"].to_i
        p.comments   = post["commentsCount"].to_i
        p.posted_at  = posted_at
        p.save!
      end
    end
  end
end

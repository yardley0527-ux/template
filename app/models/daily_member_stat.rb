class DailyMemberStat < ApplicationRecord
  validates :stat_date, presence: true, uniqueness: true

  scope :recent, ->(n = 30) { order(stat_date: :desc).limit(n) }

  def self.fetch_and_upsert_line!(date = Date.today)
    token = ENV.fetch("LINE_CHANNEL_ACCESS_TOKEN")

    followers_data = line_get(token, "https://api.line.me/v2/bot/insight/followers?date=#{date.strftime('%Y%m%d')}")
    return unless followers_data["status"] == "ready"

    stat = find_or_initialize_by(stat_date: date)
    stat.line_friends   = followers_data["targetedReaches"]
    stat.line_followers = followers_data["followers"]
    stat.line_blocks    = followers_data["blocks"]

    # 訊息量取昨日（今日 unready）
    msg_data = line_get(token, "https://api.line.me/v2/bot/insight/message/delivery?date=#{(date - 1).strftime('%Y%m%d')}")
    if msg_data["status"] == "ready"
      yesterday = find_or_initialize_by(stat_date: date - 1)
      yesterday.api_push  = msg_data["apiPush"]
      yesterday.api_reply = msg_data["apiReply"]
      yesterday.save!
    end

    stat.save!
    stat
  end

  def self.fetch_demographic
    token = ENV.fetch("LINE_CHANNEL_ACCESS_TOKEN")
    line_get(token, "https://api.line.me/v2/bot/insight/demographic")
  end

  def self.line_get(token, url)
    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = "Bearer #{token}"
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
    JSON.parse(res.body)
  end
  private_class_method :line_get
end

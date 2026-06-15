class DailyMemberStat < ApplicationRecord
  validates :stat_date, presence: true, uniqueness: true

  scope :recent, ->(n = 30) { order(stat_date: :desc).limit(n) }

  def self.fetch_and_upsert_line!(date = Date.today)
    token = ENV.fetch("LINE_CHANNEL_ACCESS_TOKEN")
    date_str = date.strftime("%Y%m%d")

    uri = URI("https://api.line.me/v2/bot/insight/followers?date=#{date_str}")
    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = "Bearer #{token}"

    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
    data = JSON.parse(res.body)

    return unless data["status"] == "ready"

    stat = find_or_initialize_by(stat_date: date)
    stat.line_friends   = data["targetedReaches"]
    stat.line_followers = data["followers"]
    stat.line_blocks    = data["blocks"]
    stat.save!
    stat
  end
end

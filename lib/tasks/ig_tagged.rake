require "net/http"
require "json"
require "csv"

# 抓「誰在 IG 上標記了這個帳號」，用 Apify 的 apify/instagram-tagged-scraper
# （$1.50 / 1000 篇貼文，比 ig:audience_analysis 用的追蹤者爬蟲便宜很多）。
# 輸出的 CSV 欄位刻意跟 hidiff/relove 那兩份手動抓的舊格式一致（ownerUsername/
# ownerFullName/ownerId/likesCount/videoPlayCount/igPlayCount/timestamp/
# paidPartnership/url），這樣可以直接接 rake brand_koc:import，不用另外轉檔。
namespace :ig_tagged do
  desc "抓某帳號的 IG 標記貼文，存成 CSV。用法：rake \"ig_tagged:fetch[bodygoalstw,body_goals]\"（可加 RESULTS_LIMIT=500 環境變數控制上限，預設 500）"
  task :fetch, [:username, :brand_key] => :environment do |_, args|
    token = ENV["APIFY_API_KEY"].presence || ENV["APIFY_TOKEN"].presence
    abort("❌ 請先設定 APIFY_API_KEY 環境變數") if token.blank?

    username = args[:username].to_s.strip.delete_prefix("@")
    brand_key = args[:brand_key].to_s.strip
    abort("❌ 用法：rake \"ig_tagged:fetch[ig帳號,brand_key]\"") if username.blank? || brand_key.blank?

    results_limit = (ENV["RESULTS_LIMIT"] || 500).to_i

    uri = URI("https://api.apify.com/v2/acts/apify~instagram-tagged-scraper/run-sync-get-dataset-items")
    uri.query = URI.encode_www_form(token: token)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 600

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = { username: [username], resultsLimit: results_limit }.to_json

    puts "抓取中：@#{username}（上限 #{results_limit} 篇標記貼文，預估費用約 $#{(results_limit / 1000.0 * 1.5).round(2)} USD）..."
    response = http.request(request)
    abort("❌ Apify 呼叫失敗：#{response.code} #{response.body}") unless response.is_a?(Net::HTTPSuccess)

    items = JSON.parse(response.body)
    date_str = Date.current.strftime("%Y-%m-%d")
    filename = "#{brand_key}_ig_mentions_#{date_str}.csv"
    out_path = Rails.root.join("data", "koc_sources", filename)

    CSV.open(out_path, "w") do |csv|
      csv << %w[ownerUsername ownerFullName ownerId likesCount videoPlayCount igPlayCount timestamp paidPartnership url]
      items.each do |item|
        csv << [
          item["ownerUsername"], item["ownerFullName"], item["ownerId"],
          item["likesCount"], item["videoPlayCount"], item["igPlayCount"],
          item["timestamp"], item["paidPartnership"], item["url"]
        ]
      end
    end

    puts "完成：#{items.size} 篇貼文 → #{out_path}"
    puts "接著執行匯入：rake \"brand_koc:import[ModelClassName,#{filename},品牌名稱]\""
  end
end

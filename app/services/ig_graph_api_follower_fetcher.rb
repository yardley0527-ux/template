# path: app/services/ig_graph_api_follower_fetcher.rb
require "net/http"
require "json"

# 用 Instagram 官方 Graph API 抓粉絲數，取代 script/fetch_ig_followers.py 那套
# 讀本機 Chrome cookie 的做法——這個可以在網頁上按按鈕觸發、在伺服器上執行，
# 不會有帳號被 IG 判定可疑登入、被鎖的風險。
#
# 前提：帳號必須是商業／創作者帳號，且已連結 Facebook 粉專（個人帳號如
# chloechao0527 不支援，繼續用原本 script/update_ig_followers.sh 手動更新）。
#
# 用法：
#   IgGraphApiFollowerFetcher.call
#   # => [ #<Result username:"shengting_official" followers:12345 error:nil>, ... ]
#
# 需要環境變數 IG_GRAPH_ACCESS_TOKEN（長效 User Access Token，
# 權限只需要 pages_show_list, pages_read_engagement, instagram_basic）。
class IgGraphApiFollowerFetcher
  GRAPH_BASE = "https://graph.facebook.com/v19.0"

  # 跟 IgFollowersController::NAMES 對齊，但排除 chloechao0527（個人帳號，Graph API 不支援）
  TARGET_USERNAMES = %w[
    shengting_official shengting.collagen shengting.vitaminbczinc shengting.bodyfit
    shengting.slim shengting.hercare shengting.vitaminDbone shengting.metabolic
    shengting.fishoil shengting.probiotic shengting.glow shengting.light shengting.eyeprotect
  ].freeze

  Result = Struct.new(:username, :followers, :error, keyword_init: true) do
    def ok? = error.nil?
  end

  def self.call = new.call

  def initialize(access_token: ENV["IG_GRAPH_ACCESS_TOKEN"])
    @access_token = access_token
  end

  def call
    return TARGET_USERNAMES.map { |u| Result.new(username: u, error: "缺少 IG_GRAPH_ACCESS_TOKEN 環境變數") } if @access_token.blank?

    pages, pages_error = fetch_linked_ig_accounts
    return TARGET_USERNAMES.map { |u| Result.new(username: u, error: pages_error) } if pages_error

    TARGET_USERNAMES.map do |username|
      ig_account = pages[username]
      next Result.new(username: username, error: "這個帳號的粉專找不到，或粉專沒有連結這個 IG 帳號") unless ig_account

      followers, err = fetch_follower_count(ig_account["id"])
      err ? Result.new(username: username, error: err) : Result.new(username: username, followers: followers)
    end
  end

  private

  # 列出這組 token 能管理的所有粉專，取出每個粉專連結的 IG 商業帳號（含 username），
  # 用 username 對回我們要追蹤的帳號清單。
  def fetch_linked_ig_accounts
    by_username = {}
    url = "#{GRAPH_BASE}/me/accounts"
    params = { fields: "instagram_business_account{id,username}", access_token: @access_token, limit: 100 }

    loop do
      body = get_json(url, params)
      return [nil, "取得粉專清單失敗：#{body.dig('error', 'message')}"] if body["error"]

      (body["data"] || []).each do |page|
        ig = page["instagram_business_account"]
        by_username[ig["username"]] = ig if ig
      end

      next_url = body.dig("paging", "next")
      break unless next_url
      url = next_url
      params = {}
    end

    [by_username, nil]
  end

  def fetch_follower_count(ig_account_id)
    body = get_json("#{GRAPH_BASE}/#{ig_account_id}", fields: "followers_count", access_token: @access_token)
    return [nil, body.dig("error", "message")] if body["error"]

    [body["followers_count"], nil]
  end

  def get_json(url, params)
    uri = URI(url)
    uri.query = URI.encode_www_form(params) if params.present?
    res = Net::HTTP.get_response(uri)
    JSON.parse(res.body)
  rescue => e
    { "error" => { "message" => "#{e.class}: #{e.message}" } }
  end
end

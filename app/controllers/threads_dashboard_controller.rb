class ThreadsDashboardController < ApplicationController
  def index
    scope = ThreadsPost.recent
      .where(keyword: ThreadsScraperService::KEYWORDS)
      .where("like_count + reply_count + repost_count >= 10")
      .order(Arel.sql("like_count + reply_count * 2 + repost_count DESC"))

    if params[:keyword].present?
      scope = scope.where(keyword: params[:keyword])
    end

    @posts         = scope.limit(60)
    @keywords      = ThreadsScraperService::KEYWORDS.sort
    @active_keyword = params[:keyword]
    @last_fetched  = ThreadsPost.maximum(:updated_at)
    @today_count   = ThreadsPost.today.count
  end

  def refresh
    success = ThreadsScraperService.run
    if success
      redirect_to threads_dashboard_path, notice: "資料已更新，共抓取 #{ThreadsPost.today.count} 則貼文"
    else
      redirect_to threads_dashboard_path, alert: "爬蟲失敗，請確認 SCRAPECREATORS_API_KEY 設定是否正確"
    end
  end

  def test_api
    require 'net/http'
    require 'json'

    api_key = ENV['SCRAPECREATORS_API_KEY']
    uri = URI("https://api.scrapecreators.com/v1/threads/search")
    uri.query = URI.encode_www_form(query: "probiotics")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.read_timeout = 30

    request = Net::HTTP::Get.new(uri)
    request["x-api-key"] = api_key.to_s

    response = http.request(request)
    render json: { status: response.code, key_prefix: api_key.to_s.first(6), body: JSON.parse(response.body) }
  rescue => e
    render json: { error: e.class.to_s, message: e.message }
  end
end

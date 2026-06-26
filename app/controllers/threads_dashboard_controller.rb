class ThreadsDashboardController < ApplicationController
  def index
    scope = ThreadsPost.recent
      .where(keyword: ThreadsScraperService::CATEGORIES)
      .where(hidden: false)
      .order(Arel.sql("reply_count * 5 + like_count DESC"))

    if params[:keyword].present?
      scope = scope.where(keyword: params[:keyword])
    end

    if params[:commented] == "yes"
      scope = scope.where(commented: true)
    elsif params[:commented] == "no"
      scope = scope.where(commented: false)
    end

    @posts              = scope.limit(60)
    @keyword_categories = ThreadsScraperService::KEYWORD_CONFIG
    @keywords           = ThreadsScraperService::ALL_LOCAL_KEYWORDS
    @active_keyword     = params[:keyword]
    @active_commented   = params[:commented]
    @last_fetched       = ThreadsPost.maximum(:updated_at)
    @today_count        = ThreadsPost.today.count
    @analysis           = ThreadsAnalysis.latest_record
  end

  def refresh
    category = params[:category].presence
    scrape_success = ThreadsScraperService.run(category: category)
    if scrape_success
      ThreadsAnalysisService.run(Date.today) if category.blank?
      msg = category.present? ?
        "「#{category}」已更新，共抓取 #{ThreadsPost.today.count} 則貼文" :
        "全部分類已更新，共抓取 #{ThreadsPost.today.count} 則貼文，AI 分析已產生"
      redirect_to threads_dashboard_path(keyword: category), notice: msg
    else
      redirect_to threads_dashboard_path, alert: "爬蟲失敗，請確認 APIFY_API_KEY 設定是否正確"
    end
  end

  def reanalyze
    api_key = ENV['ANTHROPIC_API_KEY']
    if api_key.blank?
      redirect_to threads_dashboard_path, alert: "ANTHROPIC_API_KEY 未設定，請先在 Render Environment Variables 加入"
      return
    end

    success = ThreadsAnalysisService.run(Date.today)
    if success
      redirect_to threads_dashboard_path, notice: "AI 分析重新產生完成"
    else
      redirect_to threads_dashboard_path, alert: "AI 分析失敗，請查看 Render logs"
    end
  end

  def toggle_commented
    post = ThreadsPost.find(params[:id])
    post.update!(commented: !post.commented)
    redirect_to threads_dashboard_path(keyword: params[:keyword], commented: params[:commented])
  end

  def destroy_post
    post = ThreadsPost.find(params[:id])
    post.update!(hidden: true)
    redirect_to threads_dashboard_path(keyword: params[:keyword], commented: params[:commented]), notice: "已刪除該則貼文（無正相關）"
  end

  def hidden_posts
    @posts = ThreadsPost.where(hidden: true).order(updated_at: :desc).limit(100)
  end

  def restore_post
    post = ThreadsPost.find(params[:id])
    post.update!(hidden: false)
    redirect_to threads_dashboard_hidden_path, notice: "已復原該則貼文"
  end

  def test_api
    require 'net/http'
    require 'json'

    api_key = ENV['APIFY_API_KEY']
    uri = URI("https://api.apify.com/v2/acts/automation-lab~threads-scraper/run-sync-get-dataset-items")
    uri.query = URI.encode_www_form(token: api_key.to_s)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.read_timeout = 60

    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = { mode: "search", searchQueries: ["probiotics"], maxPosts: 3 }.to_json

    response = http.request(request)
    render json: { status: response.code, key_prefix: api_key.to_s.first(6), body: JSON.parse(response.body) }
  rescue => e
    render json: { error: e.class.to_s, message: e.message }
  end
end

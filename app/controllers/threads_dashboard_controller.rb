class ThreadsDashboardController < ApplicationController
  def index
    scope = ThreadsPost.recent.order(Arel.sql("like_count + reply_count * 2 + repost_count DESC"))

    if params[:keyword].present?
      scope = scope.where(keyword: params[:keyword])
    end

    @posts         = scope.limit(60)
    @keywords      = ThreadsPost.recent.distinct.pluck(:keyword).compact.sort
    @active_keyword = params[:keyword]
    @last_fetched  = ThreadsPost.maximum(:updated_at)
    @today_count   = ThreadsPost.today.count
  end

  def refresh
    success = ThreadsScraperService.run
    if success
      redirect_to threads_dashboard_path, notice: "資料已更新，共抓取 #{ThreadsPost.today.count} 則貼文"
    else
      redirect_to threads_dashboard_path, alert: "爬蟲失敗，請確認 APIFY_TOKEN 設定是否正確"
    end
  end
end

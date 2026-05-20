class IgDashboardController < ApplicationController
  TRACKED_USERNAME = "chloechao0527"

  def index
    @profile  = IgProfile.find_by(username: TRACKED_USERNAME)
    return unless @profile

    @posts     = @profile.ig_posts.order(posted_at: :desc).limit(20)
    @snapshots = @profile.ig_snapshots.order(:snapshot_date)
  end

  def refresh
    success = IgScraperService.scrape(TRACKED_USERNAME)
    if success
      redirect_to ig_dashboard_path, notice: "資料已更新"
    else
      redirect_to ig_dashboard_path, alert: "爬蟲失敗，請確認 APIFY_TOKEN 設定"
    end
  end
end

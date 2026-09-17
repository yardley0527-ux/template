# 老闆重點關注的幾個 IG 網紅——把他們貼文/Reel 裡的團購、業配商品彙整出來。
# 抓資料走 IgScraperService（跟 ig_dashboard 共用同一條 Apify 管線），
# 判斷是不是團購/業配走 GroupBuyDetector（規則式，每篇貼文存一筆 GroupBuyDetection）。
class GroupBuyPostsController < ApplicationController
  TRACKED_USERNAMES = %w[x.yunny.x tonychu_kr kr.seafood jazz10242008].freeze

  def index
    @accounts = IgProfile.where(username: TRACKED_USERNAMES).order(:username)
    @selected_status = params[:status].presence || "待確認"
    @selected_username = params[:username].presence

    base_scope = GroupBuyDetection.joins(ig_post: :ig_profile).where(ig_profiles: { username: TRACKED_USERNAMES })
    base_scope = base_scope.where(ig_profiles: { username: @selected_username }) if @selected_username.present?

    scope = @selected_status == "全部" ? base_scope : base_scope.where(status: @selected_status)

    @detections = (@selected_status == "待確認" ? scope.order(confidence: :desc) : scope.order("ig_posts.posted_at DESC"))
                    .preload(ig_post: :ig_profile)

    @counts = base_scope.group(:status).count
  end

  def sync_account
    username = params[:username].to_s

    unless TRACKED_USERNAMES.include?(username)
      return redirect_to group_buy_posts_path, alert: "不在追蹤清單內的帳號"
    end

    if IgScraperService.scrape(username)
      redirect_to group_buy_posts_path, notice: "已同步 @#{username} 的最新貼文"
    else
      redirect_to group_buy_posts_path, alert: "@#{username} 同步失敗，請確認 APIFY_TOKEN 設定或稍後再試"
    end
  end
end

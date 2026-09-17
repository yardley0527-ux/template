namespace :group_buy_posts do
  desc "抓「網紅團購商品追蹤」頁面追蹤的所有帳號（見 GroupBuyPostsController::TRACKED_USERNAMES）"
  task sync: :environment do
    GroupBuyPostsController::TRACKED_USERNAMES.each do |username|
      puts "同步 @#{username} ..."
      success = IgScraperService.scrape(username)
      puts success ? "  完成。" : "  失敗，看 log。"
    end
  end
end

# frozen_string_literal: true
#
# 銷售日報（訂單數量、當月業績、卡別年齡、熱銷商品）。平常匯入訂單後自動發前一天的，這裡給手動用：
#
#   bundle exec rake sales_daily:print                 # 印出前一天的日報，不發
#   FROM=2026-10-16 DATE=2026-10-18 bundle exec rake sales_daily:print   # 好幾天合併（像星期一）
#   DATE=2026-10-17 FORCE=1 bundle exec rake sales_daily:line   # 推到訂閱的群組（FORCE 才會重發）

namespace :sales_daily do
  def sales_daily_date
    day = ENV["DATE"].present? ? Date.parse(ENV["DATE"]) : Date.current - 1
    ENV["FROM"].present? ? Date.parse(ENV["FROM"])..day : day
  end

  desc "Print the daily sales report. DATE=YYYY-MM-DD (order day, default yesterday)."
  task print: :environment do
    puts SalesDaily::LineDigest.new(sales_daily_date).message
  end

  desc "Push the daily sales report to subscribed LINE groups. FORCE=1 re-sends."
  task line: :environment do
    puts "[sales_daily:line] 推播 #{SalesDaily::LineDigest.call(sales_daily_date, force: ENV['FORCE'].present?)} 個群組"
  end
end

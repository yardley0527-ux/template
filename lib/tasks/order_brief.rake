# frozen_string_literal: true
#
# 每日訂單簡報（LINE Flex 卡片＋/order_briefs 明細頁）。匯入已付款訂單後會自動推前一天的，這裡給手動用：
#
#   DATE=2026-10-22 bundle exec rake order_brief:print          # 印出卡片摘要和明細頁連結，不發
#   DATE=2026-10-22 FORCE=1 bundle exec rake order_brief:line   # 推到訂閱的群組（FORCE 才會重發）

namespace :order_brief do
  def order_brief_date
    ENV["DATE"].present? ? Date.parse(ENV["DATE"]) : Date.current - 1
  end

  desc "Print the daily order brief summary. DATE=YYYY-MM-DD (default yesterday)."
  task print: :environment do
    report = OrderBrief::Report.new(order_brief_date)
    abort "#{order_brief_date} 沒有已付款訂單（還沒匯入？）" if report.empty?

    flex = OrderBrief::FlexMessage.new(report)
    puts flex.alt_text, flex.detail_url, ""
    report.level_stats.each { |l| puts "#{l[:level]} #{l[:people]} 人 $#{l[:amount].round}" }
    report.product_stats.each { |p| puts "#{p[:series]} #{p[:people]} 人，付費 #{p[:paid]} 瓶，另送 #{p[:gift]} 瓶" }
  end

  desc "Push the daily order brief to subscribed LINE groups. DATE=YYYY-MM-DD, FORCE=1 re-sends."
  task line: :environment do
    puts "[order_brief:line] 推播 #{OrderBrief::LineDigest.call(order_brief_date, force: ENV['FORCE'].present?)} 個群組"
  end
end

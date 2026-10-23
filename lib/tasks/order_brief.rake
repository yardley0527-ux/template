# frozen_string_literal: true
#
# 每日訂單簡報（LINE 版）。匯入已付款訂單後會自動推前一天的，這裡給手動用：
#
#   DATE=2026-10-22 bundle exec rake order_brief:print          # 印出簡報內容，不發
#   DATE=2026-10-22 FORCE=1 bundle exec rake order_brief:line   # 推到訂閱的群組（FORCE 才會重發）

namespace :order_brief do
  def order_brief_date
    ENV["DATE"].present? ? Date.parse(ENV["DATE"]) : Date.current - 1
  end

  desc "Print the daily order brief. DATE=YYYY-MM-DD (default yesterday)."
  task print: :environment do
    OrderBrief::LineDigest.new(order_brief_date).messages(OrderBrief::Report.new(order_brief_date)).each_with_index do |text, i|
      puts "----- 訊息 #{i + 1}（#{text.size} 字）-----", text
    end
  end

  desc "Push the daily order brief to subscribed LINE groups. DATE=YYYY-MM-DD, FORCE=1 re-sends."
  task line: :environment do
    puts "[order_brief:line] 推播 #{OrderBrief::LineDigest.call(order_brief_date, force: ENV['FORCE'].present?)} 個群組"
  end
end

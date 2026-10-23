# frozen_string_literal: true
#
# 每日訂單簡報（AI 重點＋文字總覽＋表格圖片）。匯入已付款訂單後會自動推前一天的，這裡給手動用：
#
#   DATE=2026-10-22 bundle exec rake order_brief:print          # 印出整份簡報文字（表格只印標題），不發
#   DATE=2026-10-22 bundle exec rake order_brief:images         # 只畫表格圖片、上傳 Cloudinary，印出網址，不發
#   DATE=2026-10-22 FORCE=1 bundle exec rake order_brief:line   # 推到訂閱的群組（FORCE 才會重發）

namespace :order_brief do
  def order_brief_date
    ENV["DATE"].present? ? Date.parse(ENV["DATE"]) : Date.current - 1
  end

  desc "Print the daily order brief as text (tables shown as titles). DATE=YYYY-MM-DD (default yesterday). NO_AI=1 skips AI."
  task print: :environment do
    report = OrderBrief::Report.new(order_brief_date)
    abort "#{order_brief_date} 沒有已付款訂單（還沒匯入？）" if report.empty?

    highlights = ENV["NO_AI"].present? ? nil : OrderBrief::Highlights.call(report)
    OrderBrief::LineDigest.new(order_brief_date).messages(report, highlights, images: false).each_with_index do |m, i|
      puts "===== 訊息 #{i + 1} =====", m[:text], ""
    end
  end

  desc "Render the table images, upload to Cloudinary and print their URLs (no LINE). DATE=YYYY-MM-DD"
  task images: :environment do
    report = OrderBrief::Report.new(order_brief_date)
    abort "#{order_brief_date} 沒有已付款訂單（還沒匯入？）" if report.empty?
    abort "Cloudinary 沒有設定" unless OrderBrief::ImageHost.configured?

    OrderBrief::Sections.new(report).image_sections.each_with_index do |(title, blocks), i|
      msg = OrderBrief::ImageHost.upload(OrderBrief::TableImage.new(blocks).render, day: order_brief_date, name: "test#{i}")
      puts title, msg[:originalContentUrl], ""
    end
  end

  desc "Push the daily order brief to subscribed LINE groups. DATE=YYYY-MM-DD, FORCE=1 re-sends."
  task line: :environment do
    puts "[order_brief:line] 推播 #{OrderBrief::LineDigest.call(order_brief_date, force: ENV['FORCE'].present?)} 個群組"
  end
end

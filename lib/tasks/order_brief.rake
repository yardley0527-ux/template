# frozen_string_literal: true
#
# 每日訂單簡報（AI 重點＋LINE Flex 總覽＋客人明細表格卡）。匯入已付款訂單後會自動推前一天的，這裡給手動用：
#
#   DATE=2026-10-22 bundle exec rake order_brief:print          # 印出 AI 重點和每則訊息大小，不發
#   DATE=2026-10-22 FORCE=1 bundle exec rake order_brief:line   # 推到訂閱的群組（FORCE 才會重發）

namespace :order_brief do
  def order_brief_date
    ENV["DATE"].present? ? Date.parse(ENV["DATE"]) : Date.current - 1
  end

  desc "Print the daily order brief (AI highlights + card sizes). DATE=YYYY-MM-DD (default yesterday). NO_AI=1 skips AI."
  task print: :environment do
    report = OrderBrief::Report.new(order_brief_date)
    abort "#{order_brief_date} 沒有已付款訂單（還沒匯入？）" if report.empty?

    highlights = ENV["NO_AI"].present? ? nil : OrderBrief::Highlights.call(report)
    messages = OrderBrief::LineDigest.new(order_brief_date).messages(report, highlights)
    puts OrderBrief::FlexMessage.new(report).alt_text, ""
    puts highlights ? OrderBrief::Highlights.to_text(order_brief_date, highlights) : "（沒有 AI 重點）", ""
    messages.each_with_index do |m, i|
      cards = m.dig(:contents, :contents)&.size
      puts "訊息 #{i + 1}：#{m[:type]}#{cards ? "，#{cards} 張卡" : ''}（#{m.to_json.bytesize} bytes）"
    end
  end

  desc "Push the daily order brief to subscribed LINE groups. DATE=YYYY-MM-DD, FORCE=1 re-sends."
  task line: :environment do
    puts "[order_brief:line] 推播 #{OrderBrief::LineDigest.call(order_brief_date, force: ENV['FORCE'].present?)} 個群組"
  end
end

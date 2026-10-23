# frozen_string_literal: true
#
# 把所有 LINE 報告各發一份到「一個」聊天室看樣子（例如自己的個人聊天室），不會發到群組、
# 也不會記成「已發送」，不影響之後的自動推播。個人聊天室要先私訊小幫手一次，才會出現在 /line_bot_groups。
#
#   bundle exec rake line_bot:preview TO=Serena            # TO= 聊天室名稱的一部分或 ID
#   DATE=2026-10-22 bundle exec rake line_bot:preview TO=Serena   # 訂單相關報告的日期，預設前一天

namespace :line_bot do
  desc "Send every LINE report once to a single chat as a preview. TO=name or id, DATE=YYYY-MM-DD (default yesterday)."
  task preview: :environment do
    query = ENV["TO"].presence or abort("[line_bot:preview] 要給 TO=聊天室名稱或 ID")
    chat = LineBotGroup.active.find_by(group_id: query) ||
           LineBotGroup.active.where("name ILIKE ?", "%#{LineBotGroup.sanitize_sql_like(query)}%").first
    abort("[line_bot:preview] 找不到「#{query}」；個人聊天室要先私訊小幫手一次") unless chat

    day = ENV["DATE"].present? ? Date.parse(ENV["DATE"]) : Date.current - 1
    line = LineBot::Client.new
    text = ->(str) { { type: "text", text: str.truncate(LineBot::Client::MAX_TEXT) } }
    send = lambda do |title, messages|
      line.push_messages(chat.group_id, [text.call("🧪 測試預覽｜#{title}")])
      messages.each_slice(LineBot::Client::MAX_MESSAGES) { |batch| line.push_messages(chat.group_id, batch) }
      puts "[line_bot:preview] 已發：#{title}（#{messages.size} 則）"
    rescue StandardError => e
      puts "[line_bot:preview] #{title} 失敗：#{e.class}: #{e.message}"
    end
    texts = ->(sections) { LineBot::Client.pack(sections).map(&text) }

    if (report = SeoReport.latest)
      send.call("SEO 日報", [text.call(Seo::LineDigest.new(report).message)])
    end

    brief = OrderBrief::Report.new(day)
    if brief.empty?
      puts "[line_bot:preview] #{day} 沒有訂單，略過訂單簡報和銷售日報"
    else
      send.call("訂單簡報 #{day}", OrderBrief::LineDigest.new(day).messages(brief, OrderBrief::Highlights.call(brief)))
      send.call("銷售日報 #{day}", texts.call(SalesDaily::LineDigest.new(day).sections))
    end

    send.call("黑金卡生日名單（#{Date.current} 這週）", texts.call(CrmBirthdays::LineDigest.new(Date.current).sections))

    # 前一天常常沒人回來，往前找最近一天有人的，才看得到格式
    returns_day = (0..30).map { |i| day - i }.find { |d| CrmReturns::LineDigest.new(d).returners.any? } || day
    send.call("久未消費黑金卡回來了 #{returns_day}", texts.call(CrmReturns::LineDigest.new(returns_day).sections))
  end
end

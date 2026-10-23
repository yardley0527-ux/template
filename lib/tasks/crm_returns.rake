# frozen_string_literal: true
#
# 久未消費（隔 180 天以上）的黑金卡回來下單的名單。平常匯入訂單後自動發前一天的，這裡給手動用：
#
#   bundle exec rake crm_returns:print                 # 印出前一天的名單，不發
#   DATE=2026-10-17 FORCE=1 bundle exec rake crm_returns:line   # 推到訂閱的群組（FORCE 才會重發）

namespace :crm_returns do
  def crm_returns_date
    ENV["DATE"].present? ? Date.parse(ENV["DATE"]) : Date.current - 1
  end

  desc "Print black/gold customers who came back after 180+ days. DATE=YYYY-MM-DD (order day, default yesterday)."
  task print: :environment do
    puts CrmReturns::LineDigest.new(crm_returns_date).message
  end

  desc "Push the returning black/gold list to subscribed LINE groups. FORCE=1 re-sends."
  task line: :environment do
    puts "[crm_returns:line] 推播 #{CrmReturns::LineDigest.call(crm_returns_date, force: ENV['FORCE'].present?)} 個群組"
  end
end

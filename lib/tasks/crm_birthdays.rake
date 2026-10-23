# frozen_string_literal: true
#
# CRM 群組每週生日名單（黑金卡本週生日＋接下來 3 週高消費非黑金卡）。
# 平常由 seo:daily 在週一自動發，這裡給手動用：
#
#   bundle exec rake crm_birthdays:print                # 印出本週名單，不發
#   DATE=2026-10-26 FORCE=1 bundle exec rake crm_birthdays:line   # 推到訂閱的群組（FORCE 才會重發）

namespace :crm_birthdays do
  def crm_birthdays_date
    ENV["DATE"].present? ? Date.parse(ENV["DATE"]) : Date.current
  end

  desc "Print this week's birthday list. DATE=YYYY-MM-DD (any day of the week)."
  task print: :environment do
    puts CrmBirthdays::LineDigest.new(crm_birthdays_date).message
  end

  desc "Push this week's birthday list to subscribed LINE groups. FORCE=1 re-sends."
  task line: :environment do
    puts "[crm_birthdays:line] 推播 #{CrmBirthdays::LineDigest.call(crm_birthdays_date, force: ENV['FORCE'].present?)} 個群組"
  end
end

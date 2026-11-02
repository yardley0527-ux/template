# frozen_string_literal: true
#
# IG 收件匣（/ig_inbox）：用 Meta 對話 API 抓 IG 私訊，老闆在 CRM 直接回。
# 需要 ENV：META_IG_ACCOUNTS（見 IgInbox::Client）、ANTHROPIC_API_KEY（分類與每日總結）。
# 沒有另外的 Render Cron：每小時的 manychat:sync 最後會呼叫 ig_inbox:sync。
namespace :ig_inbox do
  desc "同步 IG 私訊、分類新訊息；早上 8 點後順便整理前一天"
  task sync: :environment do
    if IgInbox::Client.accounts.empty?
      puts "[ig_inbox:sync] META_IG_ACCOUNTS 未設定，略過"
      next
    end

    IgInboxSyncJob.perform_now
    puts "[ig_inbox:sync] #{SyncRun.where(source: 'ig_inbox').order(:id).last&.meta}"
    if Time.current.hour >= 8
      digest = IgInbox::Digest.call(Date.current - 1)
      puts "[ig_inbox:sync] #{digest.day} 每日整理 #{digest.status} #{digest.error_message}"
    end
  end

  desc "整理某天的 IG 私訊（DATE=2026-11-01，預設昨天；FORCE=1 重做）"
  task digest: :environment do
    day = ENV["DATE"].present? ? Date.parse(ENV["DATE"]) : Date.current - 1
    digest = IgInbox::Digest.call(day, force: ENV["FORCE"].present?)
    puts "#{digest.day} #{digest.status} #{digest.error_message}"
    puts digest.overview
    digest.suggestions.each { |s| puts "- #{s['title']}：#{s['detail']}" }
  end

  # 設定用：Graph API Explorer 拿到的使用者權杖（1–2 小時就過期）→ 長效使用者權杖 → 不會過期的 Page token，
  # 印出 META_IG_ACCOUNTS 要填的 JSON。需要 META_APP_ID、META_APP_SECRET。
  desc "把使用者權杖換成 Page token，印出 META_IG_ACCOUNTS（USER_TOKEN=...）"
  task page_tokens: :environment do
    require "net/http"
    get = ->(path, params) do
      uri = URI("https://graph.facebook.com/#{IgInbox::Client.version}/#{path}?#{URI.encode_www_form(params)}")
      body = JSON.parse(Net::HTTP.get_response(uri).body)
      abort "Meta API 錯誤：#{body.dig('error', 'message')}" if body["error"]
      body
    end

    long = get.call("oauth/access_token", grant_type: "fb_exchange_token", client_id: ENV.fetch("META_APP_ID"),
                                          client_secret: ENV.fetch("META_APP_SECRET"), fb_exchange_token: ENV.fetch("USER_TOKEN"))
    pages = get.call("me/accounts", fields: "id,name,access_token,instagram_business_account{id,username}",
                                    access_token: long["access_token"], limit: 100)["data"]
    accounts = pages.filter_map do |p|
      ig = p["instagram_business_account"]
      next puts("（略過粉專 #{p['name']}：沒有連 IG 專業帳號）") unless ig

      { key: ig["username"], page_id: p["id"], ig_user_id: ig["id"], token: p["access_token"] }
    end
    puts "\n找到 #{accounts.size} 個 IG 帳號：#{accounts.map { |a| "@#{a[:key]}" }.join('、')}"
    puts "只留要用的帳號，整串貼到 Render 的 META_IG_ACCOUNTS：\n\n#{accounts.to_json}"
  end
end

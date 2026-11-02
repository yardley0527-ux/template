# frozen_string_literal: true
#
# ManyChat 同步（Render Cron Job：bundle exec rake manychat:sync，每小時 "0 * * * *"，在 Render 後台設定，不在 repo）。
# 試算表每列另存成一次互動（含 source 來源欄），供 /manychat_leads 新客追蹤用。
# 「未回覆問題」分頁另外匯入成 ig_questions（ENV MANYCHAT_QUESTION_TABS），早上 8 點後順便請 AI 整理前一天的，見 /ig_questions。
# 需要 ENV：MANYCHAT_SHEET_ID（Flow 寫入的 Google Sheet）、MANYCHAT_SHEET_TABS（{"分頁gid": "IG帳號"}）、MANYCHAT_API_KEYS（{"IG帳號": "金鑰"}）。
namespace :manychat do
  desc "Import ManyChat subscribers from the Google Sheet, then push CRM fields back to ManyChat"
  task sync: :environment do
    run = SyncRun.create!(source: "manychat", started_at: Time.current)
    imported = Manychat::SheetImporter.call
    puts "[manychat:sync] 試算表 #{imported}"

    # 顧客資料會隨匯入更新，未經人工確認的人重算候選；人工確認過的不動
    ManychatSubscriber.refresh_unverified_candidates!

    filled = Manychat::InteractionBackfill.call
    puts "[manychat:sync] API 補互動 checked=#{filled[:checked]} interactions=#{filled[:interactions]} errors=#{filled[:errors].size}"

    questions = Manychat::QuestionImporter.call
    puts "[manychat:sync] 未回覆問題 #{questions}"
    # 每天早上 8 點後第一次同步時，整理前一天的未回覆問題（做過就跳過）
    if Time.current.hour >= 8
      digest = Manychat::QuestionDigest.call(Date.current - 1)
      puts "[manychat:sync] #{digest.day} 未回覆問題整理 #{digest.status} #{digest.error_message}"
    end

    pushed = Manychat::CustomerFieldSync.call
    puts "[manychat:sync] 寫回欄位 synced=#{pushed[:synced]} skipped=#{pushed[:skipped]} errors=#{pushed[:errors].size}"
    pushed[:errors].first(20).each { |e| puts "  #{e}" }

    errors = filled[:errors] + pushed[:errors]
    run.update!(status: errors.empty? ? "success" : "partial", finished_at: Time.current,
                meta: { imported: imported, questions: questions, backfilled: filled.except(:errors), pushed: pushed.except(:errors) },
                error_messages: errors.first(50))
  rescue StandardError => e
    run&.update!(status: "failed", finished_at: Time.current, error_messages: ["#{e.class}: #{e.message}"])
    raise
  end

  desc "整理某天的 IG 未回覆問題（DATE=2026-11-01，預設昨天；FORCE=1 重做）"
  task question_digest: :environment do
    day = ENV["DATE"].present? ? Date.parse(ENV["DATE"]) : Date.current - 1
    digest = Manychat::QuestionDigest.call(day, force: ENV["FORCE"].present?)
    puts "#{digest.day} #{digest.status} #{digest.error_message}"
    puts digest.overview
    digest.suggestions.each { |s| puts "- #{s['title']}：#{s['detail']}" }
  end
end

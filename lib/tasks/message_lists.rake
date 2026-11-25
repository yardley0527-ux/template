# frozen_string_literal: true

namespace :message_lists do
  desc "把某天買了目標商品的客人，在還沒傳的名單上記「已買」日期（DATE=2026-11-24，預設昨天）"
  task mark_purchased: :environment do
    date = ENV["DATE"].present? ? Date.parse(ENV["DATE"]) : Date.current - 1
    results = MessageLists::MarkPurchased.call(date)
    if results.empty?
      puts "[message_lists:mark_purchased] #{date}：沒有要更新的名單"
    else
      results.each do |r|
        names = r[:recipients].map { |x| x.full_name.presence || x.email }.join("、")
        puts "[message_lists:mark_purchased] #{date} → 名單 #{r[:list].id}「#{r[:list].name}」（#{r[:list].sent_on}）已買 #{r[:recipients].size} 人：#{names}"
      end
    end
  end
end

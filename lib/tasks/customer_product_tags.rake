# frozen_string_literal: true

namespace :customers do
  desc "依已付款訂單補上客人的「購買過苼莛的產品」標籤（PDRN／冰晶番茄，只補不刪）"
  task sync_product_tags: :environment do
    CustomerProductTagSync.call.each do |tag, r|
      puts "#{tag}: 新建紀錄 #{r[:profiles_created]} 筆、補標籤 #{r[:tags_added]} 人"
    end
  end
end

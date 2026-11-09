namespace :ig_review do
  desc "匯入 IG 私訊整理結果（FILE=路徑.jsonl）；已存在的項目只更新內容，保留處理狀態與備註"
  task import: :environment do
    path = ENV.fetch("FILE")
    created = updated = 0
    File.foreach(path) do |line|
      row = JSON.parse(line)
      item = IgReviewItem.find_or_initialize_by(source_key: row.fetch("source_key"))
      item.new_record? ? created += 1 : updated += 1
      item.update!(row.slice("kind", "severity", "title", "detail", "event_codes", "customer_name", "customer_email", "as_of"))
    end
    puts "新增 #{created} 筆，更新 #{updated} 筆"
  end
end

namespace :reply_assistant do
  desc "匯入 IG 歷史問答到知識庫（FILE=路徑.jsonl，每行 question、answer）；相同內容不重複新增"
  task import_ig_history: :environment do
    created = skipped = 0
    File.foreach(ENV.fetch("FILE")) do |line|
      row = JSON.parse(line)
      item = ReplyKnowledgeItem.find_or_initialize_by(question: row.fetch("question"), answer: row.fetch("answer"), source: "ig_history")
      if item.new_record?
        item.status = "approved"
        item.save!
        created += 1
      else
        skipped += 1
      end
    end
    puts "新增 #{created} 筆，略過 #{skipped} 筆已存在"
  end
end

namespace :reply_assistant do
  desc "匯入 IG 歷史問答到知識庫（FILE=路徑.jsonl，每行 question、answer、可選 status）；相同內容不重複新增。SYNC_STATUS=1 時，已存在且仍是已核准的項目會改成檔案裡的待審／不採用"
  task import_ig_history: :environment do
    created = skipped = synced = 0
    sync = ENV["SYNC_STATUS"] == "1"
    File.foreach(ENV.fetch("FILE")) do |line|
      row = JSON.parse(line)
      status = row["status"].presence_in(ReplyKnowledgeItem::STATUSES) || "approved"
      item = ReplyKnowledgeItem.find_or_initialize_by(question: row.fetch("question"), answer: row.fetch("answer"), source: "ig_history")
      if item.new_record?
        # 有風險或需審的歷史回答先進「待審」，有時效的下單資訊「不採用」；Chloe 核准後回覆助手才會用。
        item.status = status
        item.save!
        created += 1
      elsif sync && item.status == "approved" && status != "approved"
        # 只往保守方向改，不覆蓋 Chloe 已經審過的結果。
        item.update!(status: status)
        synced += 1
      else
        skipped += 1
      end
    end
    puts "新增 #{created} 筆，改狀態 #{synced} 筆，略過 #{skipped} 筆"
  end
end

class CreateOrderBriefNotes < ActiveRecord::Migration[7.1]
  def change
    # AI 暫停期間由本機 Claude Code 寫好的訂單簡報重點（格式同 OrderBrief::Highlights），報告中心顯示用
    create_table :order_brief_notes do |t|
      t.date :report_date, null: false
      t.jsonb :highlights, null: false, default: []
      t.timestamps
    end
    add_index :order_brief_notes, :report_date, unique: true
  end
end

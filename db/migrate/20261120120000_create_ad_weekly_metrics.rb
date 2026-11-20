# frozen_string_literal: true

# 廣告週報的 Meta 數字。CRM 沒有 Meta token（9/8 決定不設），每週由 Claude 用 claude.ai 的
# Meta 連接器讀廣告帳號後寫進來；營收、新客、ManyChat 新追蹤由報告中心自己算。
class CreateAdWeeklyMetrics < ActiveRecord::Migration[7.1]
  def change
    create_table :ad_weekly_metrics do |t|
      t.date :week_end, null: false # 這週最後一天（台灣時間），一週＝week_end 往前 7 天
      t.integer :spend, null: false, default: 0 # 廣告花費（TWD）
      t.integer :ad_follows, null: false, default: 0 # Meta 記到廣告帶來的 IG 追蹤
      t.jsonb :notes, null: false, default: [] # 單一廣告分析的重點，每行一條
      t.timestamps
    end
    add_index :ad_weekly_metrics, :week_end, unique: true
  end
end

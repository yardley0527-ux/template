# frozen_string_literal: true

# 「重新產生報告」改成背景 job 執行（見 WeeklyBriefingRegenerationJob）後，
# 這欄記錄「現在有一次重新產生正在跑」，跟 status（上一次成功產生的結果）
# 分開：畫面在背景處理期間繼續顯示舊報告內容＋一個「產生中」banner，
# 而不是被清空或蓋成 pending 狀態。job 完成（成功或失敗）都要把這欄清回 nil。
class AddRegenerationStartedAtToWeeklyBriefings < ActiveRecord::Migration[7.1]
  def change
    add_column :weekly_briefings, :regeneration_started_at, :datetime
  end
end

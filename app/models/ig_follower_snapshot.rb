# path: app/models/ig_follower_snapshot.rb
class IgFollowerSnapshot < ApplicationRecord
  validates :account, :snapshot_date, :followers, presence: true

  # 每天在網頁上按一次「立即更新」時 upsert 用：同一帳號同一天再按一次會更新掉舊數字，
  # 不會產生同一天兩筆紀錄（跟 script/fetch_ig_followers.py 對同一天的處理邏輯一致）。
  def self.upsert_today!(account:, followers:, date: Date.current)
    record = find_or_initialize_by(account: account, snapshot_date: date)
    record.followers = followers
    record.save!
    record
  end

  # 把 data/ig_followers_data.json 的歷史資料匯入這張表。正式站沒有 shell 可以手動
  # 跑一次性 rake task，所以 IgFollowersController 會在這張表是空的時候自動呼叫這個
  # method（見 backfill_if_empty!），不需要人工介入。
  def self.backfill_from_json!(path = Rails.root.join("data", "ig_followers_data.json"))
    return 0 unless File.exist?(path)

    imported = 0
    JSON.parse(File.read(path)).each do |account, entries|
      entries.each do |entry|
        followers = entry["followers"]
        next if followers.nil?

        upsert_today!(account: account, followers: followers, date: Date.parse(entry["date"]))
        imported += 1
      end
    end
    imported
  end

  def self.backfill_if_empty!
    return unless count.zero?

    backfill_from_json!
  end
end

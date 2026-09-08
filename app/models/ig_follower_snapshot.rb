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
end

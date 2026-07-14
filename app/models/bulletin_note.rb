# frozen_string_literal: true

# 首頁佈告欄：隨手記的待辦/備忘。刻意不做任務系統（無指派、無截止日）——
# 就是一張全公司看得到的便條板。
class BulletinNote < ApplicationRecord
  DONE_RETENTION_DAYS = 14 # 完成超過兩週的自動清掉，板子不會無限長

  validates :content, presence: true, length: { maximum: 500 }

  scope :open_notes, -> { where(done: false).order(created_at: :desc) }
  scope :recently_done, -> { where(done: true).order(done_at: :desc) }

  def self.board
    purge_stale_done!
    open_notes.to_a + recently_done.limit(10).to_a
  end

  def self.purge_stale_done!
    where(done: true).where(done_at: ...DONE_RETENTION_DAYS.days.ago).delete_all
  end

  def toggle_done!(user)
    if done?
      update!(done: false, done_at: nil)
    else
      update!(done: true, done_at: Time.current)
    end
  end
end

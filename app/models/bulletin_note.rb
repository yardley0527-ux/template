# frozen_string_literal: true

# 佈告欄便條：隨手記的待辦/備忘。刻意不做任務系統（無指派、無截止日）。
# department 為 NULL 是首頁的全公司板；有值是該部門自己的板。
class BulletinNote < ApplicationRecord
  DONE_RETENTION_DAYS = 14 # 完成超過兩週的自動清掉，板子不會無限長

  validates :content, presence: true, length: { maximum: 500 }
  validates :department, inclusion: { in: DepartmentUpdate::DEPARTMENTS }, allow_nil: true

  scope :open_notes, -> { where(done: false).order(created_at: :desc) }
  scope :recently_done, -> { where(done: true).order(done_at: :desc) }
  scope :for_board, ->(department) { where(department: department) }

  def self.board(department = nil)
    purge_stale_done!
    scoped = for_board(department)
    scoped.open_notes.to_a + scoped.recently_done.limit(10).to_a
  end

  # 各部門板的未完成數（首頁部門卡的角標用）
  def self.open_counts_by_department
    where(done: false).where.not(department: nil).group(:department).count
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

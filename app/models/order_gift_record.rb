class OrderGiftRecord < ApplicationRecord
  validates :order_number, presence: true, uniqueness: true

  before_save :stamp_followed_up_at

  private

  # 第一次填追蹤備註時記下追蹤時間；備註被清空則一併清掉，
  # 追蹤成效的回購判斷以此時間為準
  def stamp_followed_up_at
    return unless follow_up_note_changed?

    self.followed_up_at = follow_up_note.present? ? (followed_up_at || Time.current) : nil
  end
end

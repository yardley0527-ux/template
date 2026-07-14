# frozen_string_literal: true

# 部門佈告欄裡的自訂板（「周待辦」「月待辦」是固定板，不進這張表）。
class BulletinSection < ApplicationRecord
  FIXED = %w[周待辦 月待辦].freeze

  validates :department, presence: true, inclusion: { in: DepartmentUpdate::DEPARTMENTS }
  validates :name, presence: true, length: { maximum: 50 },
                   uniqueness: { scope: :department },
                   exclusion: { in: FIXED, message: "是內建板，不用另外建" }

  # 部門板要顯示的板名（依序）：固定板 → 自訂板 → 便條裡出現但沒登記的板
  def self.names_for(department, note_sections: [])
    custom = where(department: department).order(:created_at).pluck(:name)
    (FIXED + custom + note_sections).uniq
  end
end

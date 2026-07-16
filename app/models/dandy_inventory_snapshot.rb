# frozen_string_literal: true

# DANDY 產品庫存試算表的每日解析快照，由 DandyInventorySync 同步進來。
# data 結構：
#   supplements: 保健品庫存總表（庫存_X月 分頁）
#   accessories: 按摩棒、藥盒即時庫存＋當月每日異動
class DandyInventorySnapshot < ApplicationRecord
  validates :snapshot_date, presence: true, uniqueness: true

  def self.latest
    order(snapshot_date: :desc).first
  end

  def supplements
    data["supplements"] || {}
  end

  def accessories
    data["accessories"] || {}
  end
end

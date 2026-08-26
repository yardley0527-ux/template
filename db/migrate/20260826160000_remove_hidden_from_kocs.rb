# 使用者 2026-08-26 要求拿掉 KOC 名單的「隱藏」功能（軟封存），
# 之後不想看到的人直接刪除，不需要一個中間的隱藏狀態。
class RemoveHiddenFromKocs < ActiveRecord::Migration[7.1]
  def change
    remove_column :kocs, :hidden, :boolean, default: false, null: false
  end
end

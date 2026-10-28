# 「已合作」狀態改名為「已合作、已匯款」，所有共用同一組狀態的名單一起轉換既有資料。
class RenameStatusYihezuoToYihezuoYihuikuan < ActiveRecord::Migration[7.1]
  TABLES = %i[kocs betterbio_kocs akimia_kocs relove_kocs dianbopopo_kocs decopop_kocs mirae_kocs body_goals_kocs kol_contacts kol_candidates podcast_contacts].freeze

  def up
    TABLES.each { |t| execute "UPDATE #{t} SET status = '已合作、已匯款' WHERE status = '已合作'" }
  end

  def down
    TABLES.each { |t| execute "UPDATE #{t} SET status = '已合作' WHERE status = '已合作、已匯款'" }
  end
end

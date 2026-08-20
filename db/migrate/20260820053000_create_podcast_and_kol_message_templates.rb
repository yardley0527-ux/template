# Podcast/KOL 聯絡名單頁補上「發送訊息內容」區塊，比照 Hiff KOC 業配名單頁。
class CreatePodcastAndKolMessageTemplates < ActiveRecord::Migration[7.1]
  def change
    create_table :podcast_message_templates do |t|
      t.text :content, null: false, default: ""

      t.timestamps
    end

    create_table :kol_message_templates do |t|
      t.text :content, null: false, default: ""

      t.timestamps
    end
  end
end

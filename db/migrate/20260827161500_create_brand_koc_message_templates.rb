# Relove/Body Goals/好好生醫/Dianbopopo/微電流面膜 這 5 個品牌業配名單頁補上
# 「發送訊息內容」功能，各自獨立一張表——不跟 Hiff 的 koc_message_templates
# 共用同一筆資料，避免改其中一個品牌的訊息會連帶改到別的品牌。
class CreateBrandKocMessageTemplates < ActiveRecord::Migration[7.1]
  def change
    create_table :relove_koc_message_templates do |t|
      t.text :content, null: false, default: ""
      t.timestamps
    end

    create_table :body_goals_koc_message_templates do |t|
      t.text :content, null: false, default: ""
      t.timestamps
    end

    create_table :betterbio_koc_message_templates do |t|
      t.text :content, null: false, default: ""
      t.timestamps
    end

    create_table :dianbopopo_koc_message_templates do |t|
      t.text :content, null: false, default: ""
      t.timestamps
    end

    create_table :akimia_koc_message_templates do |t|
      t.text :content, null: false, default: ""
      t.timestamps
    end
  end
end

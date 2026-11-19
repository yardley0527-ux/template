# frozen_string_literal: true

# 每週五「Claude SEO 外掛每週報告」（yardley.tw）：全站健檢 issues＋搜尋數據 insights；跟上週比較用。
# 「SEO 日報」群組（目前只有苼莛國際-總編輯）自動加訂「每週全站健檢」。
class CreateSeoSiteAudits < ActiveRecord::Migration[7.1]
  def up
    create_table :seo_site_audits do |t|
      t.string :site, null: false
      t.date :audited_on, null: false
      t.integer :pages_checked, null: false, default: 0
      t.integer :pages_skipped, null: false, default: 0
      t.jsonb :issues, null: false, default: []
      t.jsonb :insights, null: false, default: {}
      t.timestamps
    end
    add_index :seo_site_audits, %i[site audited_on], unique: true

    execute <<~SQL
      UPDATE line_bot_groups
      SET subscriptions = array_append(subscriptions, 'site_health')
      WHERE 'seo_daily' = ANY(subscriptions) AND NOT ('site_health' = ANY(subscriptions))
    SQL
  end

  def down
    execute "UPDATE line_bot_groups SET subscriptions = array_remove(subscriptions, 'site_health')"
    drop_table :seo_site_audits
  end
end

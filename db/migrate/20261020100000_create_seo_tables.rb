# SEO 每日監控：跟 SEO 公司合作結束後改成自己盯數據。
# seo_daily_metrics 存 Search Console 每站每日總數（可回補 16 個月歷史），
# seo_reports 一天一份，存當天的健康檢查結果＋關鍵字/頁面漲跌，頁面跟通知板都讀這張。
class CreateSeoTables < ActiveRecord::Migration[7.1]
  def change
    create_table :seo_daily_metrics do |t|
      t.string  :site, null: false
      t.date    :date, null: false
      t.integer :clicks, null: false, default: 0
      t.integer :impressions, null: false, default: 0
      t.decimal :ctr, precision: 8, scale: 6
      t.decimal :position, precision: 8, scale: 2
      t.timestamps
    end
    add_index :seo_daily_metrics, [:site, :date], unique: true

    create_table :seo_reports do |t|
      t.date   :report_date, null: false
      t.string :status, null: false, default: "running"
      t.jsonb  :data, null: false, default: {}
      t.text   :error_message
      t.timestamps
    end
    add_index :seo_reports, :report_date, unique: true
  end
end

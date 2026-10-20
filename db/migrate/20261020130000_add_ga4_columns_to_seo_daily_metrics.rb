# 第二階段：SEO 帶來的營收（GA4）。
#   ga_*       — 該站「自然搜尋」流量：工作階段、訂單數、營收（只有 yardley 有訂單）
#   referred_* — 從該站導到 yardley.tw 的流量（shengtingbio 雜誌導購成效）
class AddGa4ColumnsToSeoDailyMetrics < ActiveRecord::Migration[7.1]
  def change
    change_table :seo_daily_metrics, bulk: true do |t|
      t.integer :ga_sessions
      t.integer :ga_purchases
      t.decimal :ga_revenue, precision: 12, scale: 2
      t.integer :referred_sessions
      t.integer :referred_purchases
      t.decimal :referred_revenue, precision: 12, scale: 2
    end
  end
end

class CreateCustomerCohortStats < ActiveRecord::Migration[7.1]
  def change
    # 首購產品分析的結果表：每個客人（手機 > email 合併）一列，由 CustomerCohortStatsRefreshService
    # 在資料庫裡用 SQL 整批重算，頁面只讀這張表，不在 web 程序裡載入全部訂單
    create_table :customer_cohort_stats do |t|
      t.string  :identity_key, null: false
      t.string  :source, null: false
      t.string  :source_family
      t.date    :first_date, null: false
      t.decimal :first_amount, precision: 12, scale: 2, default: 0, null: false
      t.text    :first_items
      t.string  :level_at_first
      t.integer :after_days, default: 0, null: false
      t.decimal :after_amount, precision: 12, scale: 2, default: 0, null: false
      t.date    :first_after_date
      t.boolean :same_again, default: false, null: false
      t.string  :cross_families, array: true, default: [], null: false
      t.jsonb   :cross_revenue, default: {}, null: false
      t.date    :last_order_date
      t.text    :last_items
      t.string  :level_now
      t.boolean :upgraded, default: false, null: false
      t.bigint  :customer_id
      t.string  :name
      t.string  :instagram_account
      t.datetime :refreshed_at, null: false
    end
    add_index :customer_cohort_stats, :identity_key, unique: true
    add_index :customer_cohort_stats, [:source, :first_date]
  end
end

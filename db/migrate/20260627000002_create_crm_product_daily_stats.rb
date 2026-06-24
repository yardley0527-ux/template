class CreateCrmProductDailyStats < ActiveRecord::Migration[7.1]
  def change
    create_table :crm_product_daily_stats do |t|
      t.string  :product_key,       null: false, limit: 50
      t.date    :stat_date,         null: false

      # Status segment counts (days_left-dependent, rebuilt daily)
      # remind_now: days_until_reminder <= 0 AND days_left >= 0
      # overdue:    days_left < 0 AND days_left >= -60
      # at_risk:    days_left < -60
      # not_urgent: days_until_reminder > 0
      t.integer :not_urgent_count,  null: false, default: 0
      t.integer :remind_now_count,  null: false, default: 0
      t.integer :overdue_count,     null: false, default: 0
      t.integer :at_risk_count,     null: false, default: 0

      # Customer type counts (order_count / total_bottles, stable per tracking table)
      # vip:    order_count >= 2 AND total_bottles >= 6
      # big:    total_bottles >= 6 (not vip)
      # small:  total_bottles in [3, 5]
      # single: total_bottles < 3
      t.integer :vip_count,         null: false, default: 0
      t.integer :big_count,         null: false, default: 0
      t.integer :small_count,       null: false, default: 0
      t.integer :single_count,      null: false, default: 0

      t.datetime :refreshed_at,     null: false

      t.timestamps
    end

    add_index :crm_product_daily_stats,
              [:product_key, :stat_date],
              unique: true,
              name: "idx_crm_daily_stats_on_product_date"

    add_index :crm_product_daily_stats,
              :stat_date,
              name: "idx_crm_daily_stats_on_date"
  end
end

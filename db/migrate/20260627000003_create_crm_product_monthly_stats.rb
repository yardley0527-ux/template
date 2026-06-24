class CreateCrmProductMonthlyStats < ActiveRecord::Migration[7.1]
  def change
    create_table :crm_product_monthly_stats do |t|
      t.string  :product_key,              null: false, limit: 50
      t.date    :stat_month,               null: false  # stored as beginning_of_month

      # Natural business volume (source: ShoplineOrders)
      # new_buyers_count: COUNT(DISTINCT email WHERE order_date in month)
      t.integer :new_buyers_count,         null: false, default: 0

      # CRM activity metrics (source: OmnipotentNotificationStatuses)
      # notified_count:  .where.not(status: '未通知').where(notified_at: month)
      # replied_count:   .where(status: '已回覆').where(notified_at: month)
      # ordered_count:   .where(result: '已訂購').where(contacted_at: month)
      t.integer :notified_count,           null: false, default: 0
      t.integer :replied_count,            null: false, default: 0
      t.integer :ordered_count,            null: false, default: 0

      # Revenue (numeric to avoid float rounding; 14 digits handles up to ~NT$99B)
      # natural_revenue:        all ShoplineOrders this month, deduped by order_number
      # crm_attributed_revenue: 45-day attribution window — Phase 1 always 0.00
      t.decimal :natural_revenue,          null: false, default: 0, precision: 14, scale: 2
      t.decimal :crm_attributed_revenue,   null: false, default: 0, precision: 14, scale: 2

      t.datetime :refreshed_at,            null: false

      t.timestamps
    end

    add_index :crm_product_monthly_stats,
              [:product_key, :stat_month],
              unique: true,
              name: "idx_crm_monthly_stats_on_product_month"

    add_index :crm_product_monthly_stats,
              :stat_month,
              name: "idx_crm_monthly_stats_on_month"
  end
end

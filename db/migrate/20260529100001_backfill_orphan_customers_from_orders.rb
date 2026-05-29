class BackfillOrphanCustomersFromOrders < ActiveRecord::Migration[7.1]
  def up
    # 找出有訂單但無客戶檔案的 email，從訂單資料重建客戶檔案
    execute <<~SQL
      INSERT INTO shopline_customers (
        email, full_name, membership_level, instagram_account,
        total_amount, order_count, created_at, updated_at
      )
      SELECT
        o.email,
        -- 最近一筆訂單的客戶姓名
        (SELECT customer_name FROM shopline_orders
         WHERE email = o.email ORDER BY order_date DESC LIMIT 1),
        -- 最高卡別（取最近一筆有卡別的訂單）
        (SELECT membership_level FROM shopline_orders
         WHERE email = o.email AND membership_level IS NOT NULL
         ORDER BY order_date DESC LIMIT 1),
        -- 最近一筆有 IG 的訂單
        (SELECT instagram_account FROM shopline_orders
         WHERE email = o.email AND instagram_account IS NOT NULL AND instagram_account != ''
         ORDER BY order_date DESC LIMIT 1),
        -- 訂單金額加總
        SUM(COALESCE(o.checkout_amount, o.total_amount)),
        COUNT(*),
        NOW(),
        NOW()
      FROM shopline_orders o
      LEFT JOIN shopline_customers c ON c.email = o.email
      WHERE c.id IS NULL
        AND o.email IS NOT NULL
        AND o.email != ''
      GROUP BY o.email
    SQL
  end

  def down
    # 只刪除由本次 migration 補建的紀錄（shopline_id 為 NULL 且 source_row_hash 為 NULL）
    # 注意：這只是近似的 rollback，正式環境建議手動確認
    execute <<~SQL
      DELETE FROM shopline_customers
      WHERE shopline_id IS NULL
        AND source_row_hash IS NULL
        AND created_at >= '#{Time.now.utc.strftime("%Y-%m-%d %H:00:00")}'
    SQL
  end
end

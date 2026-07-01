# app/services/customer_series_loyalty_refresh_service.rb
# frozen_string_literal: true

class CustomerSeriesLoyaltyRefreshService
  SERIES_OPTIONS = %w[
    代謝錠 全能 薑黃 膠原蛋白 美白 蝦紅素 清纖粉 魚油 私密粉 益生菌 穀胱甘肽 維DK鈣
  ].freeze

  IRON_FAN_THRESHOLD  = 5  # 鐵粉
  LOYAL_THRESHOLD     = 3  # 忠實客
  REPURCHASE_THRESHOLD = 2 # 回購客
  GROWTH_MIN_ORDERS  = 3   # 至少要有幾筆訂單才計算成長趨勢，避免雜訊

  def self.call
    new.call
  end

  def call
    ActiveRecord::Base.transaction do
      rebuild!
      Rails.cache.delete_matched("loyal_customers:*")
    end
    true
  end

  private

  def rebuild!
    series_array_sql = SERIES_OPTIONS
      .map { |s| ActiveRecord::Base.connection.quote(s) }
      .join(", ")

    sql = <<~SQL
      WITH raw_matches AS (
        SELECT
          so.email,
          so.order_number,
          so.product_name,
          so.order_date,
          COALESCE(so.checkout_amount, so.total_amount, 0) AS row_amount,
          sa.series,
          COUNT(*) OVER (
            PARTITION BY so.email, so.order_number, so.product_name
          ) AS matched_series_count
        FROM shopline_orders so
        JOIN (SELECT unnest(ARRAY[#{series_array_sql}]) AS series) sa
          ON so.product_name LIKE '%' || sa.series || '%'
        WHERE so.email IS NOT NULL
          AND so.email <> ''
          AND so.order_number IS NOT NULL
          AND so.order_number <> ''
          AND so.product_name IS NOT NULL
          AND so.product_name <> ''
      ),

      order_series AS (
        SELECT
          email,
          order_number,
          series,
          MIN(order_date) AS order_date,
          SUM(row_amount / matched_series_count::numeric) AS order_amount
        FROM raw_matches
        GROUP BY email, order_number, series
      ),

      aggregated AS (
        SELECT
          email,
          series,
          COUNT(DISTINCT order_number)          AS order_count,
          SUM(order_amount)                     AS total_amount,
          MIN(order_date)::date                 AS first_date,
          MAX(order_date)::date                 AS last_date,
          (NOW()::date - MAX(order_date)::date) AS days_since_last
        FROM order_series
        GROUP BY email, series
      ),

      -- 把每人每系列的訂單依時間切成前後兩半，比較平均金額判斷「越買越多」趨勢
      half_split AS (
        SELECT
          email,
          series,
          order_amount,
          NTILE(2) OVER (
            PARTITION BY email, series
            ORDER BY order_date, order_number
          ) AS half
        FROM order_series
      ),

      half_avg AS (
        SELECT
          email,
          series,
          AVG(order_amount) FILTER (WHERE half = 1) AS first_half_avg_amount,
          AVG(order_amount) FILTER (WHERE half = 2) AS second_half_avg_amount
        FROM half_split
        GROUP BY email, series
      )

      INSERT INTO customer_series_loyalties (
        email, series, order_count, total_amount,
        first_date, last_date, days_since_last, tier,
        first_half_avg_amount, second_half_avg_amount, growth_rate_pct, is_growing,
        created_at, updated_at
      )
      SELECT
        a.email,
        a.series,
        a.order_count,
        a.total_amount,
        a.first_date,
        a.last_date,
        a.days_since_last,
        CASE
          WHEN a.order_count >= #{IRON_FAN_THRESHOLD} THEN '鐵粉'
          WHEN a.order_count >= #{LOYAL_THRESHOLD}    THEN '忠實客'
          ELSE '回購客'
        END AS tier,
        CASE WHEN a.order_count >= #{GROWTH_MIN_ORDERS} THEN ha.first_half_avg_amount END,
        CASE WHEN a.order_count >= #{GROWTH_MIN_ORDERS} THEN ha.second_half_avg_amount END,
        CASE
          WHEN a.order_count >= #{GROWTH_MIN_ORDERS} AND COALESCE(ha.first_half_avg_amount, 0) > 0
          THEN ROUND(((ha.second_half_avg_amount - ha.first_half_avg_amount) / ha.first_half_avg_amount) * 100, 1)
        END AS growth_rate_pct,
        (
          a.order_count >= #{GROWTH_MIN_ORDERS}
          AND ha.second_half_avg_amount > ha.first_half_avg_amount
        ) AS is_growing,
        NOW(),
        NOW()
      FROM aggregated a
      LEFT JOIN half_avg ha ON ha.email = a.email AND ha.series = a.series
      WHERE a.order_count >= #{REPURCHASE_THRESHOLD}
      ON CONFLICT (email, series) DO UPDATE SET
        order_count             = EXCLUDED.order_count,
        total_amount            = EXCLUDED.total_amount,
        first_date              = EXCLUDED.first_date,
        last_date               = EXCLUDED.last_date,
        days_since_last         = EXCLUDED.days_since_last,
        tier                    = EXCLUDED.tier,
        first_half_avg_amount   = EXCLUDED.first_half_avg_amount,
        second_half_avg_amount  = EXCLUDED.second_half_avg_amount,
        growth_rate_pct         = EXCLUDED.growth_rate_pct,
        is_growing              = EXCLUDED.is_growing,
        updated_at              = NOW()
    SQL

    ActiveRecord::Base.connection.execute(sql)
  end
end
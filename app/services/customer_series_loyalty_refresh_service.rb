# app/services/customer_series_loyalty_refresh_service.rb
# frozen_string_literal: true

class CustomerSeriesLoyaltyRefreshService
  SERIES_OPTIONS = %w[
    代謝錠 全能 薑黃 膠原蛋白 美白 蝦紅素 清纖粉 魚油 私密粉 益生菌 穀胱甘肽 維DK鈣
  ].freeze

  IRON_FAN_THRESHOLD  = 5  # 鐵粉
  LOYAL_THRESHOLD     = 3  # 忠實客
  REPURCHASE_THRESHOLD = 2 # 回購客

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
    sql = <<~SQL
      WITH order_series AS (
        SELECT
          so.email,
          so.order_number,
          MIN(so.order_date) AS order_date,
          MAX(COALESCE(so.checkout_amount, so.total_amount, 0)) AS order_amount,
          #{series_match_case_sql("so.product_name")} AS series
        FROM shopline_orders so
        WHERE so.email IS NOT NULL
          AND so.email <> ''
          AND so.order_number IS NOT NULL
          AND so.order_number <> ''
          AND so.product_name IS NOT NULL
          AND so.product_name <> ''
          AND #{series_where_clause}
        GROUP BY so.email, so.order_number, series
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
        WHERE series IS NOT NULL
        GROUP BY email, series
      )

      INSERT INTO customer_series_loyalties (
        email, series, order_count, total_amount,
        first_date, last_date, days_since_last, tier,
        created_at, updated_at
      )
      SELECT
        email,
        series,
        order_count,
        total_amount,
        first_date,
        last_date,
        days_since_last,
        CASE
          WHEN order_count >= #{IRON_FAN_THRESHOLD}  THEN '鐵粉'
          WHEN order_count >= #{LOYAL_THRESHOLD}     THEN '忠實客'
          WHEN order_count >= #{REPURCHASE_THRESHOLD} THEN '回購客'
          ELSE '單次'
        END AS tier,
        NOW(),
        NOW()
      FROM aggregated
      WHERE order_count >= #{REPURCHASE_THRESHOLD}
      ON CONFLICT (email, series) DO UPDATE SET
        order_count    = EXCLUDED.order_count,
        total_amount   = EXCLUDED.total_amount,
        first_date     = EXCLUDED.first_date,
        last_date      = EXCLUDED.last_date,
        days_since_last = EXCLUDED.days_since_last,
        tier           = EXCLUDED.tier,
        updated_at     = NOW()
    SQL

    ActiveRecord::Base.connection.execute(sql)
  end

  def series_match_case_sql(column)
    cases = SERIES_OPTIONS.map do |s|
      pattern = ActiveRecord::Base.connection.quote("%#{s}%")
      result  = ActiveRecord::Base.connection.quote(s)
      "WHEN #{column} LIKE #{pattern} THEN #{result}"
    end.join("\n")

    "CASE #{cases} ELSE NULL END"
  end

  def series_where_clause
    conditions = SERIES_OPTIONS.map do |s|
      "so.product_name LIKE #{ActiveRecord::Base.connection.quote("%#{s}%")}"
    end.join(" OR ")
    "(#{conditions})"
  end
end
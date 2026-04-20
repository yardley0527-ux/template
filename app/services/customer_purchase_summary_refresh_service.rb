# app/services/customer_purchase_summary_refresh_service.rb
# frozen_string_literal: true

class CustomerPurchaseSummaryRefreshService
  SERIES_OPTIONS = %w[代謝錠 全能 薑黃 膠原蛋白 美白 蝦紅素 清纖粉 魚油 私密粉 益生菌 穀胱甘肽 維DK鈣].freeze

  def self.call
    new.call
  end

  def call
    sql = <<~SQL
      INSERT INTO customer_purchase_summaries
        (email, first_product, first_series, first_date, first_amount, purchase_count, silent_only, created_at, updated_at)
      SELECT
        fp.email,
        fp.first_product,
        CASE
          #{series_case_sql("fp.first_product")}
          ELSE NULL
        END AS first_series,
        fp.first_date,
        fp.first_amount,
        COALESCE(oc.purchase_count, 1) AS purchase_count,
        CASE WHEN COALESCE(oc.purchase_count, 1) = 1 THEN TRUE ELSE FALSE END AS silent_only,
        NOW(),
        NOW()
      FROM (
        SELECT DISTINCT ON (email)
          email,
          product_name AS first_product,
          order_date   AS first_date,
          total_amount AS first_amount
        FROM shopline_orders
        WHERE email IS NOT NULL AND email != ''
          AND product_name IS NOT NULL AND product_name != ''
        ORDER BY email, order_date ASC
      ) fp
      LEFT JOIN (
        SELECT email, COUNT(DISTINCT order_number) AS purchase_count
        FROM shopline_orders
        WHERE email IS NOT NULL AND email != ''
        GROUP BY email
      ) oc ON oc.email = fp.email
      ON CONFLICT (email) DO UPDATE SET
        first_product   = EXCLUDED.first_product,
        first_series    = EXCLUDED.first_series,
        first_date      = EXCLUDED.first_date,
        first_amount    = EXCLUDED.first_amount,
        purchase_count  = EXCLUDED.purchase_count,
        silent_only     = EXCLUDED.silent_only,
        updated_at      = NOW()
    SQL

    ActiveRecord::Base.connection.execute(sql)
    Rails.cache.delete_matched("first_purchase:*")
    true
  end

  private

  def series_case_sql(column_name)
    SERIES_OPTIONS.map do |series|
      sanitized = ActiveRecord::Base.connection.quote("%#{series}%")
      "WHEN #{column_name} LIKE #{sanitized} THEN #{ActiveRecord::Base.connection.quote(series)}"
    end.join("\n")
  end
end
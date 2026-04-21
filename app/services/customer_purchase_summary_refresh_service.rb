# frozen_string_literal: true

class CustomerPurchaseSummaryRefreshService
  SERIES_OPTIONS = %w[
    代謝錠 全能 薑黃 膠原蛋白 美白 蝦紅素 清纖粉 魚油 私密粉 益生菌 穀胱甘肽 維DK鈣
  ].freeze

  SERIES_SILENT_DAYS_MAP = {
    "代謝錠" => 30,
    "全能" => 45,
    "薑黃" => 60,
    "膠原蛋白" => 45,
    "美白" => 60,
    "蝦紅素" => 50,
    "清纖粉" => 25,
    "魚油" => 75,
    "私密粉" => 30,
    "益生菌" => 30,
    "穀胱甘肽" => 60,
    "維DK鈣" => 90
  }.freeze

  DEFAULT_SILENT_DAYS_THRESHOLD = 45

  def self.call
    new.call
  end

  def call
    ActiveRecord::Base.transaction do
      rebuild_summary_table!
      Rails.cache.delete_matched("first_purchase:*")
    end

    true
  end

  private

  def rebuild_summary_table!
    sql = <<~SQL
      WITH normalized_orders AS (
        SELECT
          so.email,
          so.order_number,
          MIN(so.order_date) AS order_date,
          MAX(COALESCE(so.checkout_amount, so.total_amount, 0)) AS order_amount
        FROM shopline_orders so
        WHERE so.email IS NOT NULL
          AND so.email <> ''
          AND so.order_number IS NOT NULL
          AND so.order_number <> ''
        GROUP BY so.email, so.order_number
      ),

      ranked_orders AS (
        SELECT
          no.*,
          ROW_NUMBER() OVER (
            PARTITION BY no.email
            ORDER BY no.order_date ASC, no.order_number ASC
          ) AS order_rank,
          COUNT(*) OVER (PARTITION BY no.email) AS purchase_count,
          MAX(no.order_date) OVER (PARTITION BY no.email) AS last_order_date
        FROM normalized_orders no
      ),

      first_order AS (
        SELECT *
        FROM ranked_orders
        WHERE order_rank = 1
      ),

      second_order AS (
        SELECT *
        FROM ranked_orders
        WHERE order_rank = 2
      ),

      first_order_items AS (
        SELECT
          fo.email,
          so.product_name
        FROM first_order fo
        INNER JOIN shopline_orders so
          ON so.email = fo.email
         AND so.order_number = fo.order_number
        WHERE so.product_name IS NOT NULL
          AND so.product_name <> ''
      ),

      second_order_items AS (
        SELECT
          so2.email,
          so.product_name
        FROM second_order so2
        INNER JOIN shopline_orders so
          ON so.email = so2.email
         AND so.order_number = so2.order_number
        WHERE so.product_name IS NOT NULL
          AND so.product_name <> ''
      ),

      first_order_series_ranked AS (
        SELECT
          foi.email,
          #{series_match_case_sql("foi.product_name")} AS matched_series,
          foi.product_name,
          ROW_NUMBER() OVER (
            PARTITION BY foi.email
            ORDER BY
              CASE
                #{series_priority_case_sql("foi.product_name")}
                ELSE 999
              END ASC,
              foi.product_name ASC
          ) AS rn
        FROM first_order_items foi
      ),

      second_order_series_ranked AS (
        SELECT
          soi.email,
          #{series_match_case_sql("soi.product_name")} AS matched_series,
          soi.product_name,
          ROW_NUMBER() OVER (
            PARTITION BY soi.email
            ORDER BY
              CASE
                #{series_priority_case_sql("soi.product_name")}
                ELSE 999
              END ASC,
              soi.product_name ASC
          ) AS rn
        FROM second_order_items soi
      ),

      first_order_picked AS (
        SELECT
          fosr.email,
          fosr.product_name AS first_product,
          fosr.matched_series AS first_series
        FROM first_order_series_ranked fosr
        WHERE fosr.rn = 1
      ),

      second_order_picked AS (
        SELECT
          sosr.email,
          sosr.product_name AS second_product,
          sosr.matched_series AS second_series
        FROM second_order_series_ranked sosr
        WHERE sosr.rn = 1
      )

      INSERT INTO customer_purchase_summaries (
        email,
        first_order_number,
        first_product,
        first_series,
        first_date,
        first_amount,
        second_order_number,
        second_product,
        second_series,
        second_date,
        purchase_count,
        silent_only,
        silent_days_threshold,
        last_order_date,
        created_at,
        updated_at
      )
      SELECT
        fo.email,
        fo.order_number AS first_order_number,
        fop.first_product,
        fop.first_series,
        fo.order_date AS first_date,
        COALESCE(fo.order_amount, 0) AS first_amount,
        so.order_number AS second_order_number,
        sop.second_product,
        sop.second_series,
        so.order_date AS second_date,
        fo.purchase_count,
        CASE
          WHEN fo.purchase_count = 1
           AND fo.order_date <= NOW() - (
             INTERVAL '1 day' * (
               CASE
                 #{silent_days_case_sql("fop.first_series")}
                 ELSE #{DEFAULT_SILENT_DAYS_THRESHOLD}
               END
             )
           )
          THEN TRUE
          ELSE FALSE
        END AS silent_only,
        CASE
          #{silent_days_case_sql("fop.first_series")}
          ELSE #{DEFAULT_SILENT_DAYS_THRESHOLD}
        END AS silent_days_threshold,
        fo.last_order_date,
        NOW(),
        NOW()
      FROM first_order fo
      LEFT JOIN first_order_picked fop
        ON fop.email = fo.email
      LEFT JOIN second_order so
        ON so.email = fo.email
      LEFT JOIN second_order_picked sop
        ON sop.email = fo.email
      ON CONFLICT (email) DO UPDATE SET
        first_order_number      = EXCLUDED.first_order_number,
        first_product           = EXCLUDED.first_product,
        first_series            = EXCLUDED.first_series,
        first_date              = EXCLUDED.first_date,
        first_amount            = EXCLUDED.first_amount,
        second_order_number     = EXCLUDED.second_order_number,
        second_product          = EXCLUDED.second_product,
        second_series           = EXCLUDED.second_series,
        second_date             = EXCLUDED.second_date,
        purchase_count          = EXCLUDED.purchase_count,
        silent_only             = EXCLUDED.silent_only,
        silent_days_threshold   = EXCLUDED.silent_days_threshold,
        last_order_date         = EXCLUDED.last_order_date,
        updated_at              = NOW()
    SQL

    ActiveRecord::Base.connection.execute(sql)
  end

  def series_match_case_sql(column_name)
    case_sql = SERIES_OPTIONS.map do |series|
      pattern = ActiveRecord::Base.connection.quote("%#{series}%")
      result  = ActiveRecord::Base.connection.quote(series)
      "WHEN #{column_name} LIKE #{pattern} THEN #{result}"
    end.join("\n")

    <<~SQL.squish
      CASE
        #{case_sql}
        ELSE NULL
      END
    SQL
  end

  def series_priority_case_sql(column_name)
    SERIES_OPTIONS.each_with_index.map do |series, idx|
      pattern = ActiveRecord::Base.connection.quote("%#{series}%")
      "WHEN #{column_name} LIKE #{pattern} THEN #{idx + 1}"
    end.join("\n")
  end

  def silent_days_case_sql(column_name)
    SERIES_SILENT_DAYS_MAP.map do |series, days|
      series_sql = ActiveRecord::Base.connection.quote(series)
      "WHEN #{column_name} = #{series_sql} THEN #{days}"
    end.join("\n")
  end
end
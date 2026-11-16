# frozen_string_literal: true

class CustomerPurchaseSummaryRefreshService
  SERIES_OPTIONS = %w[
    代謝錠 全能 薑黃 膠原蛋白 美白 蝦紅素 清纖粉 魚油 私密粉 益生菌 穀胱甘肽 維DK鈣 冰晶蕃茄 PDRN 肉鹼
  ].freeze

  # 系列 → 商品名稱比對關鍵字。沒列的系列就用系列名本身。
  # 冰晶蕃茄的訂單有「蕃茄」「番茄」兩種寫法（蕃茄占大多數），兩種都要抓。
  SERIES_KEYWORDS = {
    "冰晶蕃茄" => %w[冰晶蕃茄 冰晶番茄]
  }.freeze

  SERIES_SILENT_DAYS_MAP = {
    "代謝錠"   => 56,
    "全能"     => 61,
    "薑黃"     => 63,
    "膠原蛋白"  => 54,
    "美白"     => 60,
    "蝦紅素"   => 64,
    "清纖粉"   => 46,
    "魚油"     => 71,
    "私密粉"   => 53,
    "益生菌"   => 60,
    "穀胱甘肽"  => 60,
    "維DK鈣"  => 28,
    "冰晶蕃茄" => 30, # 每瓶約 30 天（9/30 使用者指定，見 JourneyProducts）
    "PDRN"    => 20  # 每瓶可吃 15–20 天，取上限
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
    # 清除同一個人已經能用 mobile_phone 辨識，但舊的 email identity_key 還殘留的重複資料
    ActiveRecord::Base.connection.execute(<<~SQL)
      DELETE FROM customer_purchase_summaries
      WHERE identity_key = LOWER(TRIM(email))
        AND mobile_phone IS NOT NULL
        AND TRIM(mobile_phone) <> ''
    SQL

    sql = <<~SQL
      WITH valid_order_rows AS (
        -- Deduplicate identical rows from CSV import artifacts (early 2024 data has
        -- duplicate line-item rows per order, causing SUM(checkout_amount) to double).
        -- total_amount is an order-level total repeated on only some rows; MAX() is correct.
        SELECT DISTINCT
          order_number,
          email,
          order_date,
          payment_status,
          total_amount,
          checkout_amount,
          product_name
        FROM shopline_orders
        WHERE order_number IS NOT NULL
          AND TRIM(order_number) <> ''
          AND email IS NOT NULL
          AND TRIM(email) <> ''
          AND order_date IS NOT NULL
          AND payment_status = '已付款'
      ),

      normalized_orders AS (
        SELECT
          COALESCE(
            NULLIF(TRIM(sc.mobile_phone), ''),
            LOWER(TRIM(vor.email))
          ) AS identity_key,
          NULLIF(TRIM(sc.mobile_phone), '') AS mobile_phone,
          LOWER(TRIM(MIN(vor.email)))        AS email,
          vor.order_number,
          MIN(vor.order_date) AS order_date,
          CASE
            WHEN MAX(NULLIF(vor.total_amount, 0)) IS NOT NULL
            THEN MAX(NULLIF(vor.total_amount, 0))

            WHEN NULLIF(SUM(COALESCE(vor.checkout_amount, 0)), 0) IS NOT NULL
            THEN SUM(COALESCE(vor.checkout_amount, 0))

            ELSE 0
          END AS order_amount
        FROM valid_order_rows vor
        LEFT JOIN shopline_customers sc
          ON LOWER(TRIM(sc.email)) = LOWER(TRIM(vor.email))
          AND sc.mobile_phone IS NOT NULL
          AND TRIM(sc.mobile_phone) <> ''
        GROUP BY
          COALESCE(
            NULLIF(TRIM(sc.mobile_phone), ''),
            LOWER(TRIM(vor.email))
          ),
          NULLIF(TRIM(sc.mobile_phone), ''),
          vor.order_number
      ),

      ranked_orders AS (
        SELECT
          no.*,
          ROW_NUMBER() OVER (
            PARTITION BY no.identity_key
            ORDER BY no.order_date ASC, no.order_number ASC
          ) AS order_rank,
          COUNT(*) OVER (PARTITION BY no.identity_key)           AS purchase_count,
          MAX(no.order_date) OVER (PARTITION BY no.identity_key) AS last_order_date
        FROM normalized_orders no
      ),

      first_order AS (
        SELECT * FROM ranked_orders WHERE order_rank = 1
      ),

      second_order AS (
        SELECT * FROM ranked_orders WHERE order_rank = 2
      ),

      first_order_items AS (
        SELECT
          fo.identity_key,
          so.product_name
        FROM first_order fo
        INNER JOIN shopline_orders so
          ON so.order_number = fo.order_number
        WHERE so.product_name IS NOT NULL
          AND TRIM(so.product_name) <> ''
      ),

      second_order_items AS (
        SELECT
          so2.identity_key,
          so.product_name
        FROM second_order so2
        INNER JOIN shopline_orders so
          ON so.order_number = so2.order_number
        WHERE so.product_name IS NOT NULL
          AND TRIM(so.product_name) <> ''
      ),

      first_order_series_ranked AS (
        SELECT
          foi.identity_key,
          #{series_match_case_sql("foi.product_name")} AS matched_series,
          foi.product_name,
          ROW_NUMBER() OVER (
            PARTITION BY foi.identity_key
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
          soi.identity_key,
          #{series_match_case_sql("soi.product_name")} AS matched_series,
          soi.product_name,
          ROW_NUMBER() OVER (
            PARTITION BY soi.identity_key
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
          fosr.identity_key,
          fosr.product_name   AS first_product,
          fosr.matched_series AS first_series
        FROM first_order_series_ranked fosr
        WHERE fosr.rn = 1
      ),

      second_order_picked AS (
        SELECT
          sosr.identity_key,
          sosr.product_name   AS second_product,
          sosr.matched_series AS second_series
        FROM second_order_series_ranked sosr
        WHERE sosr.rn = 1
      )

      INSERT INTO customer_purchase_summaries (
        identity_key,
        mobile_phone,
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
        fo.identity_key,
        fo.mobile_phone,
        fo.email,
        fo.order_number              AS first_order_number,
        fop.first_product,
        fop.first_series,
        fo.order_date                AS first_date,
        COALESCE(fo.order_amount, 0) AS first_amount,
        so.order_number              AS second_order_number,
        sop.second_product,
        sop.second_series,
        so.order_date                AS second_date,
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
      LEFT JOIN first_order_picked  fop ON fop.identity_key = fo.identity_key
      LEFT JOIN second_order        so  ON so.identity_key  = fo.identity_key
      LEFT JOIN second_order_picked sop ON sop.identity_key = fo.identity_key
      ON CONFLICT (identity_key) DO UPDATE SET
        mobile_phone          = EXCLUDED.mobile_phone,
        email                 = EXCLUDED.email,
        first_order_number    = EXCLUDED.first_order_number,
        first_product         = EXCLUDED.first_product,
        first_series          = EXCLUDED.first_series,
        first_date            = EXCLUDED.first_date,
        first_amount          = EXCLUDED.first_amount,
        second_order_number   = EXCLUDED.second_order_number,
        second_product        = EXCLUDED.second_product,
        second_series         = EXCLUDED.second_series,
        second_date           = EXCLUDED.second_date,
        purchase_count        = EXCLUDED.purchase_count,
        silent_only           = EXCLUDED.silent_only,
        silent_days_threshold = EXCLUDED.silent_days_threshold,
        last_order_date       = EXCLUDED.last_order_date,
        updated_at            = NOW()
    SQL

    ActiveRecord::Base.connection.execute(sql)
    remove_stale_rows!
    update_first_bottles!
  end

  # 首購那筆訂單裡「首購系列」的付費瓶數：品名裡系列名後面的數字 × 數量（例：代謝錠2送1＝2、全能12送1＝12、
  # 預購-PDRN10＝10、代謝錠6薑黃6 只算代謝錠 6），送的贈品行（結帳價 0）不算；對不到數字算 1 瓶。
  def update_first_bottles!
    conn = ActiveRecord::Base.connection
    kw_values = SERIES_OPTIONS.flat_map do |series|
      (SERIES_KEYWORDS[series] || [series]).map { |kw| "(#{conn.quote(series)}, #{conn.quote(kw)})" }
    end.join(", ")
    conn.execute(<<~SQL)
      WITH kw(series, kw) AS (VALUES #{kw_values}),
      lines AS (
        SELECT DISTINCT order_number, product_name AS pn, COALESCE(NULLIF(quantity, 0), 1) AS qty, checkout_amount
        FROM shopline_orders
        WHERE payment_status = '已付款' AND COALESCE(checkout_amount, 0) > 0
      ),
      counted AS (
        SELECT cps.identity_key,
               SUM(l.qty * CASE
                 WHEN kw.series = '代謝錠' AND l.pn LIKE '%家庭號%' THEN 6
                 ELSE COALESCE(SUBSTRING(l.pn FROM kw.kw || '[^0-9送+]{0,3}(\\d+)')::int,
                               SUBSTRING(l.pn FROM '[（(](\\d+)[瓶盒]')::int, 1)
               END) AS bottles
        FROM customer_purchase_summaries cps
        JOIN lines l ON l.order_number = cps.first_order_number
        JOIN kw ON kw.series = cps.first_series AND l.pn LIKE '%' || kw.kw || '%'
        GROUP BY cps.identity_key
      )
      UPDATE customer_purchase_summaries cps
      SET first_bottles = counted.bottles
      FROM counted
      WHERE counted.identity_key = cps.identity_key
        AND cps.first_bottles IS DISTINCT FROM counted.bottles
    SQL
  end

  # 這次重算沒產生的舊列（例如客人後來補了手機，舊的 email identity_key 列還留著）會讓同一人算兩次。
  # 整個 call 在同一個 transaction 裡，NOW() 固定，所以 updated_at < NOW() 就是這次沒被重算到的列。
  # 刪除前先把人工標記（LINE 綁定、追蹤週、追蹤產品）搬到同 email 的新列。
  def remove_stale_rows!
    conn = ActiveRecord::Base.connection
    conn.execute(<<~SQL)
      UPDATE customer_purchase_summaries k
      SET line_bound        = k.line_bound OR s.line_bound,
          follow_up_week    = COALESCE(k.follow_up_week, s.follow_up_week),
          follow_up_product = COALESCE(k.follow_up_product, s.follow_up_product)
      FROM customer_purchase_summaries s
      WHERE s.updated_at < NOW()
        AND k.updated_at >= NOW()
        AND LOWER(TRIM(k.email)) = LOWER(TRIM(s.email))
        AND (s.line_bound OR s.follow_up_week IS NOT NULL OR s.follow_up_product IS NOT NULL)
    SQL
    conn.execute("DELETE FROM customer_purchase_summaries WHERE updated_at < NOW()")
  end

  # 某系列的 LIKE 條件（可能有多種寫法）。
  def series_like_sql(column_name, series)
    patterns = SERIES_KEYWORDS.fetch(series, [series]).map { |k| ActiveRecord::Base.connection.quote("%#{k}%") }
    "#{column_name} LIKE ANY (ARRAY[#{patterns.join(', ')}])"
  end

  def series_match_case_sql(column_name)
    case_sql = SERIES_OPTIONS.map do |series|
      result  = ActiveRecord::Base.connection.quote(series)
      "WHEN #{series_like_sql(column_name, series)} THEN #{result}"
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
      "WHEN #{series_like_sql(column_name, series)} THEN #{idx + 1}"
    end.join("\n")
  end

  def silent_days_case_sql(column_name)
    SERIES_SILENT_DAYS_MAP.map do |series, days|
      series_sql = ActiveRecord::Base.connection.quote(series)
      "WHEN #{column_name} = #{series_sql} THEN #{days}"
    end.join("\n")
  end
end

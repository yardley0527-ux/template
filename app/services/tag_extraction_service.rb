# path: app/services/tag_extraction_service.rb
# frozen_string_literal: true

# 「加 Tag 名單」抓取：TagExtractionRun::CATEGORIES 中每個系列，找出
# 全歷史只買過一次、且那唯一一次訂單日期落在 [range_start, range_end] 的客人。
# 沿用 2026-07-16 舊檔案（只購買一次名單）的口徑，只是限定時間窗，
# 讓後續每次抓取可以接著上一批的 range_end 繼續、不重複抓。
class TagExtractionService
  def self.call(range_start:, range_end:)
    new(range_start, range_end).call
  end

  def initialize(range_start, range_end)
    @range_start = range_start
    @range_end = range_end
  end

  def call
    rows = TagExtractionRun::CATEGORIES.flat_map { |category, pattern| fetch(category, pattern) }
    rows += fetch_new_customers
    rows += fetch_old_customer_first_purchases

    TagExtractionRun.transaction do
      run = TagExtractionRun.create!(
        range_start: @range_start,
        range_end: @range_end,
        customer_count: rows.size,
        category_counts: rows.group_by { |r| r["category"] }.transform_values(&:size)
      )

      now = Time.current
      run.recipients.insert_all!(rows.map { |r|
        {
          category: r["category"],
          email: r["email"],
          full_name: r["full_name"],
          line_id: r["line_id"],
          purchase_month: r["purchase_month"],
          product_name: r["product_name"],
          created_at: now,
          updated_at: now
        }
      }) if rows.any?

      run
    end
  end

  private

  # 全店史上第一筆已付款訂單（不限系列）落在區間內的新客；
  # 「購買產品」欄位顯示首購訂單實際的 product_name，不是固定分類標籤。
  def fetch_new_customers
    sql = <<~SQL
      WITH first_order AS (
        SELECT DISTINCT ON (LOWER(TRIM(email)))
          LOWER(TRIM(email)) AS email, order_number, order_date::date AS order_date
        FROM shopline_orders
        WHERE payment_status = '已付款' AND email IS NOT NULL
        ORDER BY LOWER(TRIM(email)), order_date ASC, order_number ASC
      ),
      qualifying AS (
        SELECT * FROM first_order
        WHERE order_date BETWEEN #{connection.quote(@range_start)} AND #{connection.quote(@range_end)}
      ),
      products AS (
        SELECT q.email, STRING_AGG(DISTINCT o.product_name, ' / ') AS product_name
        FROM qualifying q
        JOIN shopline_orders o
          ON o.order_number = q.order_number AND LOWER(TRIM(o.email)) = q.email
        WHERE o.payment_status = '已付款'
        GROUP BY q.email
      )
      SELECT
        q.email,
        COALESCE(sc.full_name, '') AS full_name,
        COALESCE(sc.line_id, '') AS line_id,
        p.product_name,
        TO_CHAR(q.order_date, 'YYYY/MM') AS purchase_month
      FROM qualifying q
      JOIN products p ON p.email = q.email
      LEFT JOIN shopline_customers sc ON LOWER(TRIM(sc.email)) = q.email
      ORDER BY q.order_date
    SQL

    connection.select_all(sql).to_a.each { |r| r["category"] = TagExtractionRun::NEW_CUSTOMER_CATEGORY }
  end

  # 「老客首購」：客人全歷史第一筆已付款訂單早於這次區間（不是完全新客），
  # 但這是他第一次買這個系列（該系列在全歷史裡最早的訂單日落在區間內）。
  # 跟 fetch（只買過一次）不同：即使這位客人之後又回購同系列，只要「這次」
  # 是他第一次買，一樣算數，不要求全歷史只買一次。
  def fetch_old_customer_first_purchases
    TagExtractionRun::PRODUCT_FAMILIES.flat_map { |family, keywords| fetch_old_first_purchase(family, keywords) }
  end

  def fetch_old_first_purchase(family, keywords)
    like_sql = keywords.map { |kw| "o.product_name ILIKE #{connection.quote("%#{kw}%")}" }.join(" OR ")

    sql = <<~SQL
      WITH family_orders AS (
        SELECT LOWER(TRIM(o.email)) AS email, o.order_date::date AS order_date
        FROM shopline_orders o
        WHERE (#{like_sql}) AND o.payment_status = '已付款' AND o.email IS NOT NULL
      ),
      first_family AS (
        SELECT email, MIN(order_date) AS first_date FROM family_orders GROUP BY email
      ),
      first_ever AS (
        SELECT LOWER(TRIM(email)) AS email, MIN(order_date::date) AS overall_first_date
        FROM shopline_orders
        WHERE payment_status = '已付款' AND email IS NOT NULL
        GROUP BY LOWER(TRIM(email))
      ),
      qualifying AS (
        SELECT ff.email, ff.first_date
        FROM first_family ff
        JOIN first_ever fe ON fe.email = ff.email
        WHERE ff.first_date BETWEEN #{connection.quote(@range_start)} AND #{connection.quote(@range_end)}
          AND ff.first_date > fe.overall_first_date
      ),
      products AS (
        SELECT q.email, STRING_AGG(DISTINCT o.product_name, ' / ') AS product_name
        FROM qualifying q
        JOIN shopline_orders o
          ON LOWER(TRIM(o.email)) = q.email AND o.order_date::date = q.first_date
        WHERE o.payment_status = '已付款' AND (#{like_sql})
        GROUP BY q.email
      )
      SELECT
        q.email,
        COALESCE(sc.full_name, '') AS full_name,
        COALESCE(sc.line_id, '') AS line_id,
        p.product_name,
        TO_CHAR(q.first_date, 'YYYY/MM') AS purchase_month
      FROM qualifying q
      JOIN products p ON p.email = q.email
      LEFT JOIN shopline_customers sc ON LOWER(TRIM(sc.email)) = q.email
      ORDER BY q.first_date
    SQL

    connection.select_all(sql).to_a.each { |r| r["category"] = TagExtractionRun.old_customer_first_purchase_category(family) }
  end

  def fetch(category, pattern)
    sql = <<~SQL
      WITH matched AS (
        SELECT LOWER(TRIM(o.email)) AS email, o.order_number, o.order_date::date AS order_date
        FROM shopline_orders o
        WHERE o.product_name ILIKE #{connection.quote(pattern)}
          AND o.payment_status = '已付款' AND o.email IS NOT NULL
      ),
      per_customer AS (
        SELECT email, COUNT(DISTINCT order_number) AS order_count, MAX(order_date) AS the_date
        FROM matched GROUP BY email
      ),
      one_timers AS (
        SELECT email, the_date FROM per_customer
        WHERE order_count = 1 AND the_date BETWEEN #{connection.quote(@range_start)} AND #{connection.quote(@range_end)}
      )
      SELECT
        ot.email,
        COALESCE(sc.full_name, '') AS full_name,
        COALESCE(sc.line_id, '') AS line_id,
        TO_CHAR(ot.the_date, 'YYYY/MM') AS purchase_month
      FROM one_timers ot
      LEFT JOIN shopline_customers sc ON LOWER(TRIM(sc.email)) = ot.email
      ORDER BY ot.the_date
    SQL

    connection.select_all(sql).to_a.each { |r| r["category"] = category }
  end

  def connection
    ActiveRecord::Base.connection
  end
end

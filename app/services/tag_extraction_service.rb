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
          created_at: now,
          updated_at: now
        }
      }) if rows.any?

      run
    end
  end

  private

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

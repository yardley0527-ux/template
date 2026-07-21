# frozen_string_literal: true

module NotificationRules
  # F. high_spender_no_second — first_amount >= 10,000, first purchase
  # 30-90 days ago, no genuine second purchase yet (def B: a paid order at
  # least 7 days after the first — matches the Phase 0-established
  # definition, excludes same-day split orders). Aggregated by
  # (first-purchase month, first_series) — never one card per customer.
  # Contactability uses shopline_customers.line_id, NOT
  # customer_purchase_summaries.line_bound (Phase 0 finding: line_bound is a
  # sparse manual flag on ~120 rows, line_id covers ~4,300 — using line_bound
  # would make almost everyone look "unreachable").
  class HighSpenderNoSecond
    THRESHOLD_AMOUNT = 10_000
    WINDOW_DAYS = (30..90).freeze
    METADATA_SAMPLE_SIZE = 50

    def self.call
      new.call
    end

    def call
      groups.filter_map { |key, rows| build(key, rows) }
    end

    private

    def groups
      from_date = Date.current - WINDOW_DAYS.end
      to_date   = Date.current - WINDOW_DAYS.begin

      sql = <<~SQL
        SELECT
          to_char(s.first_date, 'YYYY-MM') AS month,
          COALESCE(NULLIF(s.first_series, ''), '未分類') AS series,
          s.email, s.first_amount,
          (sc.line_id IS NOT NULL AND sc.line_id <> '') AS has_line_id,
          sc.id AS customer_id
        FROM customer_purchase_summaries s
        LEFT JOIN shopline_customers sc ON lower(trim(sc.email)) = lower(trim(s.email))
        WHERE s.first_amount >= #{THRESHOLD_AMOUNT}
          AND s.first_date::date BETWEEN #{ActiveRecord::Base.connection.quote(from_date)}
                                      AND #{ActiveRecord::Base.connection.quote(to_date)}
          AND NOT (
            s.purchase_count > 1 AND s.second_date IS NOT NULL
            AND s.second_date::date >= (s.first_date::date + 7)
          )
      SQL
      ActiveRecord::Base.connection.select_all(sql).to_a.group_by { |r| [r["month"], r["series"]] }
    end

    def build(key, rows)
      month, series = key
      contactable = rows.count { |r| ActiveModel::Type::Boolean.new.cast(r["has_line_id"]) }
      total_amount = rows.sum { |r| r["first_amount"].to_d }

      {
        notification_key: "high_spender_no_second", kind: "opportunity", severity: "opportunity",
        title: "#{month} 破萬新客（#{series}）：#{rows.size} 位尚未二購",
        message: "首購合計 NT$#{total_amount.to_i}，其中 #{contactable} 位有 LINE 可聯絡",
        subject_type: "high_spender_batch", subject_id: "#{month}:#{series}",
        metadata: {
          month: month, first_series: series, count: rows.size, contactable_line_id_count: contactable,
          first_amount_sum: total_amount.to_i,
          sample_shopline_customer_ids: rows.filter_map { |r| r["customer_id"] }.first(METADATA_SAMPLE_SIZE),
          query: { table: "customer_purchase_summaries", first_month: month, first_series: series,
                   first_amount_gte: THRESHOLD_AMOUNT }
        },
        deduplication_key: "high_spender_no_second:high_spender_batch:#{month}:#{series}"
      }
    end
  end
end

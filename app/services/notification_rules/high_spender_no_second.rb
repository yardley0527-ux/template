# frozen_string_literal: true

module NotificationRules
  # F. high_spender_no_second — first_amount >= 10,000, no genuine second
  # purchase yet (def B: a paid order at least 7 days after the first —
  # matches the Phase 0-established definition, excludes same-day split
  # orders). Window is per-first_series where a JourneyProducts cycle median
  # is known (0.5x-2.5x the 1-bottle median), falling back to the original
  # flat 30-90 day window when first_series doesn't match a tracked product
  # label. Aggregated by (first-purchase month, first_series) — never one
  # card per customer.
  # Contactability uses shopline_customers.line_id, NOT
  # customer_purchase_summaries.line_bound (Phase 0 finding: line_bound is a
  # sparse manual flag on ~120 rows, line_id covers ~4,300 — using line_bound
  # would make almost everyone look "unreachable").
  # NOTE: refund/cancelled-order exclusion depends on how customer_purchase_summaries
  # is built upstream — this rule only reads that cache table and cannot itself
  # tell a refunded order apart from a real one (data limitation, not fixed here).
  class HighSpenderNoSecond
    THRESHOLD_AMOUNT = 10_000
    DEFAULT_WINDOW_DAYS = NotificationRules::Thresholds::HIGH_SPENDER_WINDOW_DAYS
    WINDOW_DAYS = DEFAULT_WINDOW_DAYS # 沿用給既有呼叫端參考（實際判定改成逐列依產品週期）
    WIDE_NET_DAYS = 400 # SQL 先撈寬一點，實際窗口在 Ruby 依產品週期逐列判斷
    CYCLE_WINDOW_MULTIPLIER = (0.5..2.5)
    METADATA_SAMPLE_SIZE = 50

    def self.call
      new.call
    end

    def call
      groups.filter_map { |key, rows| build(key, rows) }
    end

    private

    def groups
      from_date = Date.current - WIDE_NET_DAYS
      to_date   = Date.current

      sql = <<~SQL
        SELECT
          to_char(s.first_date, 'YYYY-MM') AS month,
          COALESCE(NULLIF(s.first_series, ''), '未分類') AS series,
          s.email, s.first_amount, s.first_date,
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
      rows = ActiveRecord::Base.connection.select_all(sql).to_a.select { |r| within_series_window?(r) }
      rows.group_by { |r| [r["month"], r["series"]] }
    end

    # first_series 匹配得到 JourneyProducts 產品就用「1瓶回購中位數 × 0.5~2.5」
    # 當窗口（還沒到週期一半不算過早，超過2.5倍中位數視為冷名單、留給 vip_silent
    # 之類的規則處理，避免無限期一直出現在這裡）；匹配不到就退回原本固定 30-90 天。
    def within_series_window?(row)
      days_since_first = (Date.current - row["first_date"].to_date).to_i
      window = series_window(row["series"])
      window.cover?(days_since_first)
    end

    def series_window(series)
      @series_window_cache ||= {}
      @series_window_cache[series] ||= begin
        product = JourneyProducts::PRODUCTS.values.find { |p| series.to_s.include?(p[:label]) || series.to_s.include?(p[:short]) }
        median = product&.dig(:medians, 1)
        if median
          (median * CYCLE_WINDOW_MULTIPLIER.begin).round..(median * CYCLE_WINDOW_MULTIPLIER.end).round
        else
          DEFAULT_WINDOW_DAYS
        end
      end
    end

    def build(key, rows)
      month, series = key
      contactable = rows.count { |r| ActiveModel::Type::Boolean.new.cast(r["has_line_id"]) }
      total_amount = rows.sum { |r| r["first_amount"].to_d }

      {
        notification_key: "high_spender_no_second", kind: "opportunity", severity: "opportunity", priority: "P2",
        title: "#{month} 破萬新客（#{series}）：#{rows.size} 位尚未二購",
        message: "首購合計 NT$#{total_amount.to_i}，其中 #{contactable} 位有 LINE 可聯絡",
        impact_summary: "首購金額NT$#{total_amount.to_i}的高潛力新客還沒有第二次購買，流失風險隨時間上升。",
        recommended_action: "針對有LINE可聯絡的#{contactable}位優先發送二購引導訊息或建立客服任務。",
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

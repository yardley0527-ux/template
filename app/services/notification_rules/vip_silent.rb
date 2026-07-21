# frozen_string_literal: true

module NotificationRules
  # G. vip_silent — 黑卡/金卡 silent for 90+ days, tiered by severity
  # (90-179=opportunity, 180+=warning — never auto-critical; card tier is a
  # sort-priority signal within the expanded list, not a severity override).
  # One aggregate card per tier per week (dedup_key includes ISO week so it
  # naturally opens a fresh cycle weekly rather than staying open forever).
  class VipSilent
    TIERS = [
      { key: "90_179", range: (90..179), severity: "opportunity" },
      { key: "180_plus", range: (180..Float::INFINITY), severity: "warning" }
    ].freeze
    HIGH_CARD_LEVELS = %w[黑卡 金卡].freeze
    METADATA_SAMPLE_SIZE = 50

    def self.call
      new.call
    end

    def call
      TIERS.filter_map { |tier| build_for_tier(tier) }
    end

    private

    def build_for_tier(tier)
      rows = silent_customers(tier[:range])
      return nil if rows.empty?

      week_start = Date.current.beginning_of_week
      black_count = rows.count { |r| r["membership_level"] == "黑卡" }
      gold_count  = rows.size - black_count
      label = tier[:key] == "90_179" ? "90–179 天" : "180 天以上"

      {
        notification_key: "vip_silent_#{tier[:key]}", kind: "opportunity", severity: tier[:severity],
        title: "黑/金卡沉睡 #{label}：#{rows.size} 位（黑卡 #{black_count}／金卡 #{gold_count}）",
        message: "卡別僅供優先排序，非自動 critical",
        subject_type: "vip_silent_batch", subject_id: "#{tier[:key]}:#{week_start}",
        metadata: {
          tier: tier[:key], count: rows.size, black_count: black_count, gold_count: gold_count,
          week_start: week_start.to_s,
          sample_shopline_customer_ids: rows.filter_map { |r| r["customer_id"] }.first(METADATA_SAMPLE_SIZE),
          query: { table: "customer_purchase_summaries+shopline_customers", membership_level_in: HIGH_CARD_LEVELS,
                   silent_days_from: tier[:range].begin, silent_days_to: (tier[:range].end.finite? ? tier[:range].end : nil) }
        },
        deduplication_key: "vip_silent_#{tier[:key]}:vip_silent_batch:#{week_start}"
      }
    end

    def silent_customers(range)
      levels = HIGH_CARD_LEVELS.map { |l| ActiveRecord::Base.connection.quote(l) }.join(",")
      upper_clause = range.end.finite? ? "AND (CURRENT_DATE - cps.last_order_date::date) <= #{range.end}" : ""

      sql = <<~SQL
        SELECT sc.id AS customer_id, sc.membership_level
        FROM shopline_customers sc
        JOIN customer_purchase_summaries cps
          ON cps.identity_key = COALESCE(NULLIF(TRIM(sc.mobile_phone), ''), LOWER(TRIM(sc.email)))
        WHERE sc.membership_level IN (#{levels})
          AND (CURRENT_DATE - cps.last_order_date::date) >= #{range.begin}
          #{upper_clause}
      SQL
      ActiveRecord::Base.connection.select_all(sql).to_a
    end
  end
end

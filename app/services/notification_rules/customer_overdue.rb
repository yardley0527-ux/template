# frozen_string_literal: true

module NotificationRules
  # E. customer_overdue — overdue 1-60 days, aggregated per product,
  # split into high-value (黑/金卡 OR 末單金額≥30000) vs general pool.
  # glutathione is EXCLUDED entirely — it's a wave-restock product (see
  # Phase 0 complex-review report) where a fixed day-count overdue window
  # doesn't hold; it needs a to-be-built restock-triggered rule instead.
  # qingxian/simi carry an "估計值" (estimated) badge in the title —
  # their repurchase-cycle medians are known-uncalibrated (Phase 0 finding).
  class CustomerOverdue
    OVERDUE_WINDOW = (1..60).freeze # 沿用給 NotificationCustomerListService 以外的呼叫端參考
    BANDS = NotificationRules::Thresholds::OVERDUE_BANDS
    HIGH_VALUE_MEMBERSHIP = %w[黑卡 金卡].freeze
    HIGH_VALUE_AMOUNT = 30_000
    EXCLUDED_PRODUCTS = %w[glutathione].freeze
    ESTIMATED_CYCLE_PRODUCTS = %w[qingxian simi].freeze
    METADATA_SAMPLE_SIZE = 50

    def self.call
      new.call
    end

    def call
      (JourneyProducts::PRODUCTS.keys - EXCLUDED_PRODUCTS).flat_map { |key| build_for_product(key) }
    end

    private

    def build_for_product(product_key)
      crm_product = NotificationRules::ProductKeyMapping.crm_product_for(product_key)
      return [] if crm_product && %w[out_of_stock discontinued].include?(crm_product.availability_status)

      today = Date.current
      BANDS.filter_map { |band| build_band(product_key, crm_product, today, band) }
    end

    def build_band(product_key, crm_product, today, band)
      rows = high_value_split(product_key, today, band[:range])
      total = rows[:high_value_count] + rows[:general_count]
      return nil if total.zero?

      label = JourneyProducts::PRODUCTS.fetch(product_key)[:label]
      estimate_tag = ESTIMATED_CYCLE_PRODUCTS.include?(product_key) ? "（週期為估計值）" : ""
      band_label = band[:range].end.infinite? ? "#{band[:range].begin} 天以上" : "#{band[:range].begin}–#{band[:range].end} 天"
      # 逾期天數越久優先權越低（越冷的名單），但這個區間裡只要有高價值客就整段升一級——
      # 高價值客不能因為區間本身偏冷就被埋掉。
      base_priority = case band[:key]
                       when "1_14", "15_30", "31_60" then "P2"
                       else "P3"
                       end
      priority = rows[:high_value_count].positive? ? bump_priority(base_priority) : base_priority
      severity = rows[:high_value_count].positive? ? "warning" : "opportunity"

      {
        notification_key: "customer_overdue_#{band[:key]}", kind: "opportunity", severity: severity,
        priority: priority,
        title: "#{label}#{estimate_tag}逾期#{band_label}：#{total} 位客人未回購（含高價值 #{rows[:high_value_count]} 位）",
        message: "逾期#{band_label}，高價值客（黑/金卡或末單≥NT$#{HIGH_VALUE_AMOUNT}）優先",
        impact_summary: "#{total} 位客人逾期未回購（高價值 #{rows[:high_value_count]} 位），逾期越久轉換率通常越低。",
        recommended_action: "依會員等級與歷史消費排序，優先聯繫高價值客。",
        subject_type: "journey_product", subject_id: product_key,
        metadata: {
          product_key: product_key, total_count: total, high_value_count: rows[:high_value_count],
          general_count: rows[:general_count], band: band[:key],
          availability_status: crm_product&.availability_status || "unknown",
          estimated_cycle: ESTIMATED_CYCLE_PRODUCTS.include?(product_key),
          sample_shopline_customer_ids: rows[:sample_customer_ids],
          query: { table: "crm_customer_product_trackings", product_key: product_key,
                   overdue_days_from: band[:range].begin,
                   overdue_days_to: band[:range].end.infinite? ? 3650 : band[:range].end }
        },
        deduplication_key: "customer_overdue_#{band[:key]}:journey_product:#{product_key}"
      }
    end

    def bump_priority(priority)
      { "P3" => "P2", "P2" => "P1", "P1" => "P0" }.fetch(priority, priority)
    end

    # 一次 SQL 算出高價值/一般兩桶計數與抽樣 shopline_customer_id，
    # 避免對每位客人各自查一次。
    def high_value_split(product_key, today, range)
      from_date = today - (range.end.infinite? ? 3650 : range.end)
      to_date   = today - range.begin
      levels = HIGH_VALUE_MEMBERSHIP.map { |l| ActiveRecord::Base.connection.quote(l) }.join(",")

      sql = <<~SQL
        SELECT
          sc.id AS customer_id,
          (sc.membership_level IN (#{levels}) OR
           (SELECT MAX(so.checkout_amount) FROM shopline_orders so
            WHERE so.email = t.email AND so.order_date::date = t.last_order_date) >= #{HIGH_VALUE_AMOUNT}
          ) AS is_high_value
        FROM crm_customer_product_trackings t
        LEFT JOIN shopline_customers sc ON lower(trim(sc.email)) = lower(trim(t.email))
        WHERE t.product_key = #{ActiveRecord::Base.connection.quote(product_key)}
          AND t.expected_return_date BETWEEN #{ActiveRecord::Base.connection.quote(from_date)}
                                          AND #{ActiveRecord::Base.connection.quote(to_date)}
      SQL
      result = ActiveRecord::Base.connection.select_all(sql).to_a

      high_value = result.select { |r| ActiveModel::Type::Boolean.new.cast(r["is_high_value"]) }
      general    = result - high_value

      {
        high_value_count: high_value.size,
        general_count: general.size,
        sample_customer_ids: (high_value + general).first(METADATA_SAMPLE_SIZE).filter_map { |r| r["customer_id"] }
      }
    end
  end
end

# frozen_string_literal: true

module NotificationRules
  # D. customer_runout — customers about to run out (0-7 days), aggregated
  # ONE notification per product (never one per customer — fatigue control).
  # 8-14 day customers are NOT a separate notification, only a heads-up
  # count folded into this same card's metadata. Skips discontinued/
  # out_of_stock products entirely (nothing to sell them). preorder products
  # DO generate, tagged "預購中" in the title per spec.
  class CustomerRunout
    PREVIEW_WINDOW = (8..14).freeze
    METADATA_SAMPLE_SIZE = 50
    # 8/27 使用者要求：原本 0–3 天(P1) / 4–7 天(P2) 拆兩張卡改成單一張
    # 0–7 天(P1)，不再細分。
    BANDS = [
      { key: "p1", range: NotificationRules::Thresholds::RUNOUT_DAYS, priority: "P1", label: "0–7 天" }
    ].freeze

    def self.call
      new.call
    end

    def call
      JourneyProducts::PRODUCTS.keys.flat_map { |key| build_for_product(key) }
    end

    private

    def build_for_product(product_key)
      crm_product = NotificationRules::ProductKeyMapping.crm_product_for(product_key)
      return [] if crm_product && %w[out_of_stock discontinued].include?(crm_product.availability_status)

      today = Date.current
      base = CrmCustomerProductTracking.where(product_key: product_key)
      preview_count = base.where(expected_return_date: (today + PREVIEW_WINDOW.begin)..(today + PREVIEW_WINDOW.end)).count

      BANDS.filter_map { |band| build_band(product_key, crm_product, base, today, band, preview_count) }
    end

    def build_band(product_key, crm_product, base, today, band, preview_count)
      rows = base.where(expected_return_date: (today + band[:range].begin)..(today + band[:range].end))
      return nil if rows.empty?

      sample_customer_ids = shopline_customer_ids(rows.limit(METADATA_SAMPLE_SIZE).pluck(:email))
      label = JourneyProducts::PRODUCTS.fetch(product_key)[:label]
      preorder_tag = crm_product&.preorder? ? "（預購中）" : ""

      {
        notification_key: "customer_runout_#{band[:key]}", kind: "opportunity", severity: "opportunity",
        priority: band[:priority],
        title: "#{label}#{preorder_tag}：#{rows.count} 位客人剩餘 #{band[:label]} 即將用完",
        message: "8–14 天內還有 #{preview_count} 位將進入提醒窗",
        impact_summary: "#{rows.count} 位客人即將沒有#{label}可用，是回購訊息時效性最高的一批。",
        recommended_action: "發送回購提醒訊息或建立客服任務主動聯繫。",
        subject_type: "journey_product", subject_id: product_key,
        metadata: {
          product_key: product_key, count: rows.count, band: band[:key], runout_8_14_preview_count: preview_count,
          availability_status: crm_product&.availability_status || "unknown",
          sample_shopline_customer_ids: sample_customer_ids,
          query: { table: "crm_customer_product_trackings", product_key: product_key,
                   expected_return_date_from: (today + band[:range].begin).to_s,
                   expected_return_date_to: (today + band[:range].end).to_s }
        },
        deduplication_key: "customer_runout_#{band[:key]}:journey_product:#{product_key}"
      }
    end

    def shopline_customer_ids(emails)
      return [] if emails.empty?

      ShoplineCustomer.where(email: emails).limit(METADATA_SAMPLE_SIZE).pluck(:id)
    end
  end
end

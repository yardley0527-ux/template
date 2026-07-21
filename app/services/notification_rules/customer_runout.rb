# frozen_string_literal: true

module NotificationRules
  # D. customer_runout — customers about to run out (0-7 days), aggregated
  # ONE notification per product (never one per customer — fatigue control).
  # 8-14 day customers are NOT a separate notification, only a heads-up
  # count folded into this same card's metadata. Skips discontinued/
  # out_of_stock products entirely (nothing to sell them). preorder products
  # DO generate, tagged "預購中" in the title per spec.
  class CustomerRunout
    RUNOUT_WINDOW = (0..7).freeze
    PREVIEW_WINDOW = (8..14).freeze
    METADATA_SAMPLE_SIZE = 50

    def self.call
      new.call
    end

    def call
      JourneyProducts::PRODUCTS.keys.filter_map { |key| build_for_product(key) }
    end

    private

    def build_for_product(product_key)
      crm_product = NotificationRules::ProductKeyMapping.crm_product_for(product_key)
      return nil if crm_product && %w[out_of_stock discontinued].include?(crm_product.availability_status)

      today = Date.current
      base = CrmCustomerProductTracking.where(product_key: product_key)
      runout_rows = base.where(expected_return_date: (today + RUNOUT_WINDOW.begin)..(today + RUNOUT_WINDOW.end))
      return nil if runout_rows.empty?

      preview_count = base.where(expected_return_date: (today + PREVIEW_WINDOW.begin)..(today + PREVIEW_WINDOW.end)).count
      sample_customer_ids = shopline_customer_ids(runout_rows.limit(METADATA_SAMPLE_SIZE).pluck(:email))
      label = JourneyProducts::PRODUCTS.fetch(product_key)[:label]
      preorder_tag = crm_product&.preorder? ? "（預購中）" : ""

      {
        notification_key: "customer_runout", kind: "opportunity", severity: "opportunity",
        title: "#{label}#{preorder_tag}：#{runout_rows.count} 位客人 7 天內即將用完",
        message: "8–14 天內還有 #{preview_count} 位將進入提醒窗",
        subject_type: "journey_product", subject_id: product_key,
        metadata: {
          product_key: product_key, count: runout_rows.count, runout_8_14_preview_count: preview_count,
          availability_status: crm_product&.availability_status || "unknown",
          sample_shopline_customer_ids: sample_customer_ids,
          query: { table: "crm_customer_product_trackings", product_key: product_key,
                   expected_return_date_from: (today + RUNOUT_WINDOW.begin).to_s,
                   expected_return_date_to: (today + RUNOUT_WINDOW.end).to_s }
        },
        deduplication_key: "customer_runout:journey_product:#{product_key}"
      }
    end

    def shopline_customer_ids(emails)
      return [] if emails.empty?

      ShoplineCustomer.where(email: emails).limit(METADATA_SAMPLE_SIZE).pluck(:id)
    end
  end
end

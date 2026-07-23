# frozen_string_literal: true

module NotificationRules
  # I. promotion_opportunity — a JourneyProducts-tracked product just started
  # showing a discount on yardley.tw (this scrape's ProductPromotionSnapshot
  # is on_sale? and the previous one wasn't). Fires once per promotion: once
  # the following day's snapshot confirms the discount is still running
  # (prior snapshot now also on_sale?), the transition condition goes false
  # and this card is not returned again, so NotificationEngine auto-resolves
  # it — deliberately a single heads-up, not a running "still on sale" badge
  # (bundle-tier discounts like buy-3-get-1 are permanent fixtures, not
  # events, and would otherwise renotify forever).
  #
  # Customer segment reuses CustomerOverdue's exact window (overdue 1-60
  # days) rather than a bespoke promo-specific window, so "who should get
  # this" stays defined in one place.
  class PromotionOpportunity
    OVERDUE_WINDOW = (1..60).freeze
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

      latest, prior = ProductPromotionSnapshot.for_product(product_key).limit(2).to_a
      return nil unless newly_discounted?(latest, prior)

      today = Date.current
      rows = CrmCustomerProductTracking.where(product_key: product_key)
                                        .where(expected_return_date: (today - OVERDUE_WINDOW.end)..(today - OVERDUE_WINDOW.begin))
      count = rows.count
      return nil if count.zero?

      label = JourneyProducts::PRODUCTS.fetch(product_key)[:label]

      {
        notification_key: "promotion_opportunity", kind: "opportunity", severity: "opportunity",
        title: "#{label}官網現正優惠中（省#{latest.discount_pct}%）：#{count} 位客人在回購窗口內",
        message: "#{latest.product_name} NT$#{latest.sale_price}（原價 NT$#{latest.regular_price}），逾期 1–60 天客群，建議發送名單",
        subject_type: "journey_product", subject_id: product_key,
        metadata: {
          product_key: product_key, discount_pct: latest.discount_pct.to_f,
          sale_price: latest.sale_price, regular_price: latest.regular_price,
          product_url: latest.product_url, count: count,
          sample_shopline_customer_ids: shopline_customer_ids(rows.limit(METADATA_SAMPLE_SIZE).pluck(:email)),
          query: { table: "crm_customer_product_trackings", product_key: product_key,
                   overdue_days_from: OVERDUE_WINDOW.begin, overdue_days_to: OVERDUE_WINDOW.end }
        },
        deduplication_key: "promotion_opportunity:journey_product:#{product_key}"
      }
    end

    def newly_discounted?(latest, prior)
      return false unless latest&.on_sale?

      prior.nil? || !prior.on_sale?
    end

    def shopline_customer_ids(emails)
      return [] if emails.empty?

      ShoplineCustomer.where(email: emails).limit(METADATA_SAMPLE_SIZE).pluck(:id)
    end
  end
end

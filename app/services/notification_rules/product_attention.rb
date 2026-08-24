# frozen_string_literal: true

module NotificationRules
  # H. product_attention — week-over-week revenue surge/drop, ONE card per
  # product max. Trend conclusions gated on CrmProduct#product_trend_detection_enabled?
  # (Phase 0A model method — true only for in_stock/low_stock; unknown,
  # out_of_stock, preorder, discontinued never produce a trend conclusion,
  # satisfying "unknown 不下異常結論" for free by reusing the already-shipped
  # method rather than re-deriving the same rule here). A DROP is further
  # suppressed if either this week or last week overlaps a livestream D0-D3
  # attribution window (natural post-livestream falloff, not a real drop);
  # growth is never suppressed by livestream context.
  class ProductAttention
    GROWTH_THRESHOLD_PCT = 50
    DROP_THRESHOLD_PCT = -50
    MIN_BASELINE_AMOUNT = 10_000 # 前週基期太小時百分比會失真，先過濾掉
    DROP_MIN_ABSOLUTE_GAP = 15_000 # 百分比達標但絕對金額差太小時降級（P3），避免小基期產品被過度示警

    def self.call
      new.call
    end

    def call
      JourneyProducts::PRODUCTS.each_key.filter_map { |key| build_for_product(key) }
    end

    private

    def build_for_product(product_key)
      crm_product = NotificationRules::ProductKeyMapping.crm_product_for(product_key)
      return nil unless crm_product&.product_trend_detection_enabled?

      product = JourneyProducts::PRODUCTS.fetch(product_key)
      this_week = revenue_for(product[:sql], 7.days.ago.beginning_of_day, Time.current)
      last_week = revenue_for(product[:sql], 14.days.ago.beginning_of_day, 7.days.ago.beginning_of_day)
      return nil if last_week < MIN_BASELINE_AMOUNT

      pct = ((this_week - last_week) / last_week * 100).round(1)
      return nil if pct.between?(DROP_THRESHOLD_PCT, GROWTH_THRESHOLD_PCT)
      return nil if pct.negative? && livestream_window_overlap?

      surge = pct.positive?
      absolute_gap = (this_week - last_week).abs
      # 下降但絕對金額差太小（基期小、百分比容易失真）就降到 P3 觀察，不是 P1/P2 警訊。
      priority = if surge
                   "P2"
                 elsif absolute_gap < DROP_MIN_ABSOLUTE_GAP
                   "P3"
                 else
                   "P1"
                 end
      {
        notification_key: "product_attention", kind: surge ? "opportunity" : "alert",
        severity: surge ? "opportunity" : "warning", priority: priority,
        title: "#{product[:label]}週營收#{surge ? '成長' : '下降'} #{pct.abs}%",
        message: "本週 NT$#{this_week.to_i}，前週 NT$#{last_week.to_i}（庫存狀態：#{status_label(crm_product)}）",
        impact_summary: surge ? "週營收成長#{pct.abs}%（NT$#{absolute_gap.to_i}），可觀察是否延續。" \
                                : "週營收下降#{pct.abs}%（NT$#{absolute_gap.to_i}），且非直播D0-D3窗口內的自然回落。",
        recommended_action: surge ? "確認是否有可延續的行銷動作，考慮加碼。" : "確認是否缺貨、匯入延遲或活動結束造成，非單純銷售力下降才需要進一步處理。",
        subject_type: "journey_product", subject_id: product_key,
        metadata: {
          product_key: product_key, this_week_revenue: this_week.to_i, last_week_revenue: last_week.to_i,
          pct: pct.to_f, absolute_gap: absolute_gap.to_i, availability_status: crm_product.availability_status,
          livestream_context: livestream_window_overlap?
        },
        deduplication_key: "product_attention:journey_product:#{product_key}"
      }
    end

    def revenue_for(sql_pattern, from, to)
      ShoplineOrder.where(sql_pattern).where(order_date: from..to).sum(:checkout_amount).to_d
    end

    def livestream_window_overlap?
      @livestream_window_overlap = Livestream.where(date: 17.days.ago.to_date..Date.current).exists? if @livestream_window_overlap.nil?
      @livestream_window_overlap
    end

    def status_label(crm_product)
      CrmProduct::AVAILABILITY_STATUS_LABELS.fetch(crm_product.availability_status, crm_product.availability_status)
    end
  end
end

# frozen_string_literal: true

module NotificationRules
  # B. inventory_attention — crm_products.availability_status is now the
  # source of truth (Phase 0A). discontinued products are excluded from
  # every check here (spec: "discontinued 不提醒"). unknown products get a
  # single weekly aggregate notice, never a per-product conclusion.
  class InventoryAttention
    RECENT_SALES_WINDOW = 7.days
    ZERO_SALES_CHECK_DAYS = 3

    def self.call
      new.call
    end

    def call
      products = CrmProduct.confirmed.where.not(availability_status: "discontinued")
      [] + stock_conflicts(products) + overdue_restock(products) + zero_sales_after_restock(products) +
        unknown_weekly_summary(products)
    end

    private

    # 標缺貨/預購但近 7 天實際有銷售 —— 資料在說謊，critical。
    def stock_conflicts(products)
      products.where(availability_status: %w[out_of_stock preorder]).filter_map do |p|
        recent_revenue = recent_checkout_amount(p, since: RECENT_SALES_WINDOW.ago)
        next if recent_revenue.zero?

        build(key: "inventory_stock_conflict", severity: "critical", priority: "P0", product: p,
             title: "#{p.label}標記為#{status_label(p.availability_status)}，但近 7 天仍有銷售",
             message: "近 7 天 checkout_amount 合計 NT$#{recent_revenue.to_i}，請確認庫存狀態",
             impact_summary: "庫存狀態資料與實際銷售矛盾，回購/逾期判定可能全部失真。",
             recommended_action: "確認實際庫存並更新 crm_products.availability_status。",
             metadata: { availability_status: p.availability_status, recent_checkout_amount: recent_revenue.to_i })
      end
    end

    # 預計到貨日已過，狀態仍是 out_of_stock（沒人工確認實際到貨）。
    def overdue_restock(products)
      products.where(availability_status: "out_of_stock")
              .where.not(expected_restock_date: nil)
              .where("expected_restock_date < ?", Date.current)
              .filter_map do |p|
        days = (Date.current - p.expected_restock_date).to_i
        build(key: "inventory_restock_overdue", severity: "warning", priority: "P1", product: p,
             title: "#{p.label}預計到貨日已過 #{days} 天，庫存狀態尚未確認",
             message: "預計到貨日：#{p.expected_restock_date}，請確認是否已到貨",
             impact_summary: "庫存狀態卡在缺貨，這段期間的回購提醒都會被排除，可能漏掉真的可以下單的客人。",
             recommended_action: "確認到貨日期是否已更新，並回填實際到貨日。",
             metadata: { expected_restock_date: p.expected_restock_date.to_s, days_overdue: days })
      end
    end

    # 到貨後 3 天仍零銷售（warning，非 critical——單純到貨未上架也可能是原因）。
    def zero_sales_after_restock(products)
      products.where(availability_status: %w[in_stock low_stock])
              .where.not(actual_restock_date: nil)
              .where("actual_restock_date <= ?", Date.current - ZERO_SALES_CHECK_DAYS)
              .filter_map do |p|
        since_restock = recent_checkout_amount(p, since: p.actual_restock_date.beginning_of_day)
        next if since_restock.positive?

        build(key: "inventory_zero_sales_after_restock", severity: "warning", priority: "P2", product: p,
             title: "#{p.label}到貨後已 #{ZERO_SALES_CHECK_DAYS}+ 天，尚無銷售",
             message: "實際到貨日：#{p.actual_restock_date}，請確認是否已上架",
             impact_summary: "可能是還沒上架、還沒開賣，也可能是真的賣不動——系統只能看訂單資料，" \
                             "沒有商品頁流量／加入購物車資料可以進一步判斷原因（資料不足）。",
             recommended_action: "確認商品是否已上架可購買，排除上架延遲後再觀察銷量。",
             metadata: { actual_restock_date: p.actual_restock_date.to_s, availability_status: p.availability_status })
      end
    end

    # unknown 狀態：一週一張彙總卡，不對個別產品下結論。dedup_key 含當週週一
    # 日期，讓它每週自然開新一輪（而非永遠卡在同一張直到人工關閉）。
    def unknown_weekly_summary(products)
      unknown = products.where(availability_status: "unknown")
      return [] if unknown.empty?

      week_start = Date.current.beginning_of_week
      [{
        notification_key: "inventory_unknown_weekly", kind: "alert", severity: "info", priority: "P3",
        title: "#{unknown.count} 個產品庫存狀態尚未確認",
        message: "庫存未確認期間，這些產品不會產生缺貨/成長/下降類的提醒判定",
        impact_summary: "這些產品完全沒有庫存判定，可能漏掉真正的缺貨或銷售異常。",
        recommended_action: "逐一確認這些產品目前的實際庫存狀態。",
        subject_type: "crm_product_batch", subject_id: nil,
        metadata: { count: unknown.count, product_keys: unknown.pluck(:key), week_start: week_start.to_s },
        deduplication_key: "inventory_unknown_weekly:batch:#{week_start}"
      }]
    end

    def recent_checkout_amount(product, since:)
      return 0.to_d if product.sql_pattern.blank?

      ShoplineOrder.where(product.sql_pattern).where("order_date >= ?", since).sum(:checkout_amount)
    end

    def status_label(status)
      CrmProduct::AVAILABILITY_STATUS_LABELS.fetch(status, status)
    end

    def build(key:, severity:, priority:, product:, title:, message:, metadata:,
              impact_summary: nil, recommended_action: nil)
      {
        notification_key: key, kind: "alert", severity: severity, priority: priority, title: title, message: message,
        impact_summary: impact_summary, recommended_action: recommended_action,
        subject_type: "crm_product", subject_id: product.id.to_s,
        metadata: metadata.merge(product_key: product.key),
        deduplication_key: "#{key}:crm_product:#{product.id}"
      }
    end
  end
end

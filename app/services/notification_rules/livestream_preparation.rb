# frozen_string_literal: true

module NotificationRules
  # K. livestream_preparation — T-3/T-1 具體檢查清單（取代 event_attention 原本
  # 籠統的倒數提醒）。每一項檢查都各自可判斷「完成了沒」，缺項才出卡，全部
  # 完成就不會有卡（引擎的 stale-sweep 自然把舊卡 auto-resolve）。
  #
  # UTM/活動連結沒有對應欄位可查——這項固定標記「資料不足」，不假裝檢查過。
  class LivestreamPreparation
    T_MINUS_DAYS = NotificationRules::Thresholds::PREP_T_MINUS_DAYS

    def self.call
      new.call
    end

    def call
      T_MINUS_DAYS.flat_map { |days_before| build_for_checkpoint(days_before) }
    end

    private

    def build_for_checkpoint(days_before)
      event = CalendarEvent.where(event_type: "livestream", event_date: Date.current + days_before).first
      return [] unless event

      livestream = Livestream.find_by(date: event.event_date)
      checklist = checklist_for(livestream)
      missing = checklist.reject { |item| item[:done] }
      return [] if missing.empty?

      priority = days_before == 1 ? "P1" : "P2"
      label = "T-#{days_before}"

      [{
        notification_key: "livestream_preparation_t#{days_before}", kind: "alert",
        severity: priority == "P1" ? "warning" : "opportunity", priority: priority,
        title: "直播「#{event.title}」#{label}（#{event.event_date}）：#{missing.size} 項準備尚未完成",
        message: missing.map { |i| i[:label] }.join("、"),
        impact_summary: "#{label}還有#{missing.size}項未完成，直播當天可能來不及補救。",
        recommended_action: "儘快完成：#{missing.map { |i| i[:label] }.join('、')}",
        subject_type: "calendar_event", subject_id: event.id.to_s,
        metadata: {
          event_date: event.event_date.to_s, days_before: days_before, livestream_id: livestream&.id,
          checklist: checklist, missing_items: missing.map { |i| i[:key] }
        },
        deduplication_key: "livestream_preparation_t#{days_before}:calendar_event:#{event.id}"
      }]
    end

    # UTM／活動連結沒有對應欄位（系統未儲存），依 spec「若系統有資料」的前提
    # 直接跳過這項檢查，不列進 checklist——列進去又永遠標記未完成，這張卡會
    # 變成永遠無法自動解除，跟「條件不再成立就要能自動解除」互相矛盾。
    def checklist_for(livestream)
      [
        { key: "featured_products", label: "主推商品尚未設定", done: livestream.present? && livestream.product_keys.any? },
        { key: "bundle_pricing", label: "優惠組合尚未確認", done: livestream.present? && livestream.livestream_products.any? },
        { key: "products_purchasable", label: "商品頁不可購買或庫存狀態未知", done: products_purchasable?(livestream) },
        { key: "outreach_candidates", label: "客服候選名單尚未產生", done: livestream.present? && CrmLivestreamOutreachTask.where(livestream_id: livestream.id).exists? },
        { key: "owner_assigned", label: "尚未指派負責人", done: livestream&.owner_user_id.present? }
      ]
    end

    def products_purchasable?(livestream)
      return false if livestream.blank? || livestream.product_keys.blank?

      livestream.product_keys.all? do |key|
        crm_product = CrmProduct.find_by(key: key)
        crm_product.present? && %w[in_stock low_stock preorder].include?(crm_product.availability_status)
      end
    end
  end
end

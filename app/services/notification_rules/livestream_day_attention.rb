# frozen_string_literal: true

module NotificationRules
  # L. livestream_day_attention — 直播當天即時摘要卡。沒有直播目標欄位可比較
  # （livestreams 表沒有 target 相關欄位），依 spec「沒有目標只顯示資訊摘要，
  # 不產生無根據的異常判定」，priority 固定 P3（資訊，不是警訊）。
  # 資料只到「最後一次訂單匯入完成時間」為止，卡片上會標明這個時間點，不假裝
  # 即時。
  class LivestreamDayAttention
    def self.call
      new.call
    end

    def call
      event = CalendarEvent.where(event_type: "livestream", event_date: Date.current).first
      return [] unless event

      livestream = Livestream.find_by(date: Date.current)
      last_import_at = ImportRun.where(kind: "paid_orders_workbook").maximum(:finished_at)

      attribution = livestream ? LivestreamAttribution.new(livestream, window_days: 0) : nil

      [{
        notification_key: "livestream_day_attention", kind: "alert", severity: "info", priority: "P3",
        title: "今日直播「#{event.title}」即時摘要",
        message: summary_message(attribution, last_import_at),
        impact_summary: "沒有設定直播目標，此卡僅供參考，不代表異常判定。",
        recommended_action: attribution ? "持續關注銷量走勢，D+1/D+3 會自動產出跟歷史場次的比較。" : "直播結果資料尚未匯入，稍後再查看。",
        subject_type: "calendar_event", subject_id: event.id.to_s,
        metadata: {
          event_date: event.event_date.to_s, livestream_id: livestream&.id,
          last_import_finished_at: last_import_at&.iso8601,
          revenue: attribution&.revenue&.to_i, orders: attribution&.orders, buyers: attribution&.buyers,
          new_buyers: attribution&.new_buyers,
          avg_order_value: (attribution && attribution.orders.positive? ? (attribution.revenue / attribution.orders).round(0) : nil)
        },
        deduplication_key: "livestream_day_attention:calendar_event:#{event.id}"
      }]
    end

    private

    def summary_message(attribution, last_import_at)
      import_note = last_import_at ? "截至最後一次匯入（#{last_import_at.strftime('%H:%M')}）" : "尚無匯入資料"
      return "#{import_note}：直播結果尚未有訂單資料" unless attribution && attribution.orders.positive?

      "#{import_note}：營收 NT$#{attribution.revenue.to_i}，#{attribution.orders} 筆訂單，#{attribution.buyers} 位買家" \
        "（新客 #{attribution.new_buyers} 位）"
    end
  end
end

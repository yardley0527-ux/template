# frozen_string_literal: true

module NotificationRules
  # N. livestream_review_due — 直播 D+3 仍未完成檢討升 P2，D+5 升 P1。
  # 「完成檢討」＝ livestreams.review_completed_at 有值（由
  # LivestreamsController 的專屬 action 設定，見 routes）。檢討報告本身仍是
  # 外部 Claude Artifact 連結（LivestreamReportsController::REPORTS），這裡
  # 不重造報告內容，只negotiate「有沒有完成」的旗標＋自動帶入系統可算的數字，
  # 讓管理者確認完成時不用整份重新手動輸入。
  class LivestreamReviewDue
    P2_AFTER_DAYS = NotificationRules::Thresholds::REVIEW_DUE_P2_AFTER_DAYS
    P1_AFTER_DAYS = NotificationRules::Thresholds::REVIEW_DUE_P1_AFTER_DAYS
    LOOKBACK_DAYS = 60 # 超過 60 天還沒檢討的歷史場次不再糾纏，避免舊資料洗版

    def self.call
      new.call
    end

    def call
      due_livestreams.filter_map { |ls| build(ls) }
    end

    private

    def due_livestreams
      Livestream.where(review_completed_at: nil)
                .where(date: (Date.current - LOOKBACK_DAYS)..(Date.current - P2_AFTER_DAYS))
    end

    def build(livestream)
      days_since = (Date.current - livestream.date).to_i
      priority = days_since >= P1_AFTER_DAYS ? "P1" : "P2"
      attribution = LivestreamAttribution.new(livestream, window_days: [days_since, 7].min)

      {
        notification_key: "livestream_review_due", kind: "alert",
        severity: priority == "P1" ? "warning" : "opportunity", priority: priority,
        title: "#{livestream.date} 直播檢討逾 D+#{days_since} 仍未完成",
        message: "營收 NT$#{attribution.revenue.to_i}／#{attribution.orders} 筆訂單／#{attribution.buyers} 位買家，" \
                  "點進去確認資料後標記完成",
        impact_summary: "沒有及時檢討，下一場的定價/備貨/排程建議就沒有依據。",
        recommended_action: "查看自動帶入的數據，完成檢討後標記「已完成檢討」。",
        subject_type: "livestream", subject_id: livestream.id.to_s,
        metadata: {
          livestream_date: livestream.date.to_s, days_since: days_since,
          revenue: attribution.revenue.to_i, orders: attribution.orders, buyers: attribution.buyers,
          new_buyers: attribution.new_buyers, product_rows: attribution.product_rows
        },
        deduplication_key: "livestream_review_due:livestream:#{livestream.id}"
      }
    end
  end
end

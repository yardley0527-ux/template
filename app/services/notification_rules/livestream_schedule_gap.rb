# frozen_string_literal: true

module NotificationRules
  # J. livestream_schedule_gap — 公司預期約每 14 天一場直播。以「已排定的直播
  # 活動」（CalendarEvent event_type=livestream，未來日期）為準，不是單靠訂單
  # 營收猜測有沒有直播——這條規則只看「有沒有排下一場」，跟 OpsRiskScan 檢查
  # 「已排定但品項未定/庫存衝突」是互補、不重疊的兩件事。
  #
  # 例外機制重用 CalendarEvent：event_type=livestream_pause 的區間
  # （event_date..end_date，end_date 為 nil 視為當天）覆蓋到今天就不提醒——
  # 公司排定的長假/暫停週期不用另開一張表。
  class LivestreamScheduleGap
    CYCLE_DAYS = NotificationRules::Thresholds::LIVESTREAM_CYCLE_DAYS
    P2_AFTER_DAYS = NotificationRules::Thresholds::LIVESTREAM_GAP_P2_AFTER_DAYS
    P1_AFTER_DAYS = NotificationRules::Thresholds::LIVESTREAM_GAP_P1_AFTER_DAYS
    LOOKAHEAD_DAYS = NotificationRules::Thresholds::LIVESTREAM_LOOKAHEAD_DAYS

    def self.call
      new.call
    end

    def call
      return [] if paused_today?

      last = Livestream.maximum(:date)
      return [] if last.nil?

      days_since = (Date.current - last).to_i
      return [] if days_since < P2_AFTER_DAYS
      return [] if next_scheduled.present?

      priority = days_since >= P1_AFTER_DAYS ? "P1" : "P2"
      suggested = last + CYCLE_DAYS

      [{
        notification_key: "livestream_schedule_gap", kind: "alert", severity: priority == "P1" ? "warning" : "opportunity",
        priority: priority,
        title: "距離上一場直播已 #{days_since} 天，還沒排下一場",
        message: "上一場：#{last}｜建議安排日期：約 #{suggested}（週期 #{CYCLE_DAYS} 天）",
        impact_summary: "超過預期的#{CYCLE_DAYS}天週期沒有排定下一場，回購節奏可能被打亂。",
        recommended_action: "在行事曆建立下一場直播活動，或標註暫停週期避免重複提醒。",
        subject_type: "livestream_cycle", subject_id: "current",
        metadata: {
          last_livestream_date: last.to_s, days_since_last: days_since, suggested_date: suggested.to_s,
          cycle_days: CYCLE_DAYS
        },
        deduplication_key: "livestream_schedule_gap:livestream_cycle:current"
      }]
    end

    private

    def next_scheduled
      CalendarEvent.where(event_type: "livestream")
                   .where(event_date: Date.current..(Date.current + LOOKAHEAD_DAYS))
                   .order(:event_date).first
    end

    def paused_today?
      today = Date.current
      CalendarEvent.where(event_type: "livestream_pause")
                   .where("event_date <= ? AND (end_date >= ? OR end_date IS NULL AND event_date >= ?)", today, today, today)
                   .exists?
    end
  end
end

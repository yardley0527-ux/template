# frozen_string_literal: true

module NotificationRules
  # C. event_attention — T-3/T-1 livestream countdown + D+4 weak-performance
  # check. Deliberately does NOT repeat OpsRiskScan's own checks (silent
  # department, 30-day undecided-lineup, stock/livestream date conflict —
  # already surfaced on the home page radar) — this rule only covers what
  # OpsRiskScan does not: the T-3/T-1 countdown itself, and post-livestream
  # D+4 revenue comparison (uses LivestreamAttribution, already shipped by
  # PR #43 — not re-derived here).
  class EventAttention
    COUNTDOWN_DAYS = [3, 1].freeze
    COMPARISON_COUNT = 3
    WEAK_THRESHOLD_PCT = 50 # D+4 revenue < 50% of prior N-livestream average

    def self.call
      new.call
    end

    def call
      countdown_notifications + d4_weak_notification
    end

    private

    def countdown_notifications
      COUNTDOWN_DAYS.filter_map do |days_before|
        event = CalendarEvent.where(event_type: "livestream", event_date: Date.current + days_before).first
        next unless event

        build(key: "event_countdown_t#{days_before}", severity: "info",
             title: "直播「#{event.title}」倒數 #{days_before} 天（#{event.event_date}）",
             message: event.description.presence,
             subject_type: "calendar_event", subject_id: event.id.to_s,
             metadata: { event_date: event.event_date.to_s, days_before: days_before })
      end
    end

    def d4_weak_notification
      recent = Livestream.limit(COMPARISON_COUNT + 1).to_a # default_scope: date desc
      return [] if recent.size < COMPARISON_COUNT + 1

      latest, prior = recent.first, recent[1..]
      latest_revenue = LivestreamAttribution.new(latest).revenue.to_d
      prior_avg = prior.sum { |ls| LivestreamAttribution.new(ls).revenue.to_d } / prior.size

      return [] if prior_avg.zero?

      pct = (latest_revenue / prior_avg * 100).round(1)
      return [] if pct >= WEAK_THRESHOLD_PCT

      [build(key: "event_d4_weak", severity: "warning",
            title: "#{latest.date} 直播 D0–D3 營收僅為前 #{COMPARISON_COUNT} 場均值的 #{pct}%",
            message: "本場 NT$#{latest_revenue.to_i}，前 #{COMPARISON_COUNT} 場均值 NT$#{prior_avg.to_i}",
            subject_type: "livestream", subject_id: latest.id.to_s,
            metadata: { livestream_date: latest.date.to_s, revenue: latest_revenue.to_i,
                       prior_avg_revenue: prior_avg.to_i, pct: pct.to_f })]
    end

    def build(key:, severity:, title:, message:, subject_type:, subject_id:, metadata:)
      {
        notification_key: key, kind: "alert", severity: severity, title: title, message: message,
        subject_type: subject_type, subject_id: subject_id, metadata: metadata,
        deduplication_key: "#{key}:#{subject_type}:#{subject_id}"
      }
    end
  end
end

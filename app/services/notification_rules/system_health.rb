# frozen_string_literal: true

module NotificationRules
  # A. system_health — data-pipeline freshness/failure signals. One
  # notification per distinct problem (not per source), category=system_health,
  # kind=alert always (these are never opportunities).
  class SystemHealth
    IMPORT_STALE_AFTER = 36.hours
    ROLLUP_STALE_AFTER  = 26.hours
    THREADS_STALE_AFTER = 7.days
    IMPORT_KINDS = { "paid_orders_workbook" => "訂單匯入", "customers_report" => "客戶匯入" }.freeze

    def self.call
      new.call
    end

    def call
      [] + import_staleness + rollup_staleness + sync_failures + briefing_failure + threads_staleness
    end

    private

    def import_staleness
      IMPORT_KINDS.filter_map do |kind, label|
        last_finished = ImportRun.where(kind: kind).maximum(:finished_at)
        next if last_finished.present? && last_finished >= IMPORT_STALE_AFTER.ago

        hours = last_finished.nil? ? nil : ((Time.current - last_finished) / 1.hour).round
        build(key: "system_health_import_stale", severity: "critical",
             title: "#{label}已超過 36 小時未完成",
             message: last_finished ? "最後一次完成於 #{hours} 小時前" : "從未成功完成過",
             subject_type: "import_kind", subject_id: kind,
             metadata: { kind: kind, last_finished_at: last_finished&.iso8601 })
      end
    end

    def rollup_staleness
      last = SyncRun.last_finished_at("crm_rollup")
      return [] if last.nil? || last >= ROLLUP_STALE_AFTER.ago

      hours = ((Time.current - last) / 1.hour).round
      [build(key: "system_health_rollup_stale", severity: "critical",
            title: "CRM 旅程快取已超過 26 小時未更新",
            message: "最後一次成功刷新於 #{hours} 小時前", subject_type: "sync_source", subject_id: "crm_rollup",
            metadata: { last_finished_at: last.iso8601 })]
    end

    def sync_failures
      SyncRun::SOURCES.filter_map do |source, label|
        next if source == "crm_rollup" # 已由 rollup_staleness 專門處理

        run = SyncRun.latest_for(source)
        next if run.nil? || %w[success running].include?(run.status)

        build(key: "system_health_sync_failed", severity: "warning",
             title: "#{label}同步狀態為#{run.status}",
             message: run.failed_parts.presence&.join("、"),
             subject_type: "sync_source", subject_id: source,
             metadata: { source: source, status: run.status })
      end
    end

    def briefing_failure
      latest = DailyBriefing.latest
      return [] unless latest && latest.status == "failed"

      [build(key: "system_health_briefing_failed", severity: "warning",
            title: "AI 晨報 #{latest.briefing_date} 產生失敗",
            message: latest.error_message.presence,
            subject_type: "daily_briefing", subject_id: latest.id.to_s,
            metadata: { briefing_date: latest.briefing_date.to_s })]
    end

    def threads_staleness
      last = ThreadsFetchLog.maximum(:fetched_at)
      return [] if last.nil? || last >= THREADS_STALE_AFTER.ago

      days = ((Time.current - last) / 1.day).round
      [build(key: "system_health_threads_stale", severity: "warning",
            title: "Threads 監測已超過 7 天未更新",
            message: "最後一次抓取於 #{days} 天前", subject_type: "threads_fetch_log", subject_id: nil,
            metadata: { last_fetched_at: last.iso8601 })]
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

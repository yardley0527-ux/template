# frozen_string_literal: true

require Rails.root.join("lib/notifications_maintenance_lock") if defined?(Rails)

# Orchestrator for the 8 fixed notification rule categories. Each rule class
# (app/services/notification_rules/*.rb) implements .call and returns an
# Array of result hashes:
#   { notification_key:, kind:, severity:, title:, message:, subject_type:,
#     subject_id:, metadata:, deduplication_key: }
#
# Idempotent upsert semantics (per notifications table's partial unique
# index on deduplication_key WHERE status='open'):
#   - condition still firing, dedup_key already OPEN  -> update in place
#     (bumps last_detected_at, title/message/severity/metadata refreshed;
#     first_detected_at untouched)
#   - condition firing, no OPEN row for that dedup_key -> INSERT a new row
#     (this is also how a previously-resolved condition that recurs starts
#     a fresh cycle — the old resolved row keeps its own dedup_key value,
#     the partial index only blocks two simultaneously-OPEN rows)
#   - an OPEN row in this category whose dedup_key was NOT returned this
#     run -> auto-resolved (condition cleared)
#
# One rule failing must not abort the others (per-rule rescue, mirrors
# CrmRollupRunner's per-product rescue). Runs under NotificationsMaintenanceLock
# (non-blocking — a concurrent run just skips) and always leaves a
# SyncRun(source: "notifications") trail. Never invoked via perform_later —
# production queue is :async (see Phase 0A), so this is rake-only by design,
# same as crm_rollup.
class NotificationEngine
  RULES = {
    "system_health"          => "NotificationRules::SystemHealth",
    "inventory_attention"    => "NotificationRules::InventoryAttention",
    "event_attention"        => "NotificationRules::EventAttention",
    "customer_runout"        => "NotificationRules::CustomerRunout",
    "customer_overdue"       => "NotificationRules::CustomerOverdue",
    "high_spender_no_second" => "NotificationRules::HighSpenderNoSecond",
    "vip_silent"             => "NotificationRules::VipSilent",
    "product_attention"      => "NotificationRules::ProductAttention"
  }.freeze

  def self.run_all
    new.run(RULES.keys)
  end

  def self.run_rule(category)
    raise ArgumentError, "unknown rule category: #{category.inspect}" unless RULES.key?(category)

    new.run([category])
  end

  def run(categories)
    acquired, result = NotificationsMaintenanceLock.try_with_lock { run_locked(categories) }
    return result if acquired

    { aborted: true, abort_reason: "lock_busy — another notification generation run is in progress" }
  end

  private

  def run_locked(categories)
    sync_run = SyncRun.create!(source: "notifications", status: "running", started_at: Time.current)
    per_rule = {}
    failed = []

    categories.each do |category|
      begin
        per_rule[category] = run_one_rule(category)
      rescue StandardError => e
        failed << category
        per_rule[category] = { hit_count: 0, created: 0, updated: 0, auto_resolved: 0, error: e.class.name }
      end
    end

    status = overall_status(total: categories.size, failed: failed.size)
    sync_run.update!(status: status, finished_at: Time.current, meta: safe_meta(per_rule))

    { sync_run_id: sync_run.id, status: status, per_rule: per_rule }
  end

  def run_one_rule(category)
    klass = RULES.fetch(category).constantize
    results = klass.call
    upsert_and_resolve!(category, results)
  end

  # ── Upsert / auto-resolve (fatigue-control core) ──────────────────

  def upsert_and_resolve!(category, results)
    now = Time.current
    seen_keys = []
    created = 0
    updated = 0

    results.each do |r|
      dedup_key = r.fetch(:deduplication_key)
      seen_keys << dedup_key

      existing = Notification.find_by(deduplication_key: dedup_key, status: "open")
      if existing
        existing.update!(last_detected_at: now, title: r[:title], message: r[:message],
                         severity: r[:severity], metadata: r[:metadata] || {})
        updated += 1
      else
        Notification.create!(
          notification_key: r.fetch(:notification_key), kind: r.fetch(:kind), category: category,
          severity: r.fetch(:severity), title: r.fetch(:title), message: r[:message],
          subject_type: r[:subject_type], subject_id: r[:subject_id], metadata: r[:metadata] || {},
          deduplication_key: dedup_key, status: "open", first_detected_at: now, last_detected_at: now
        )
        created += 1
      end
    end

    stale = Notification.open_status.where(category: category)
    stale = stale.where.not(deduplication_key: seen_keys) if seen_keys.any?
    auto_resolved = 0
    stale.find_each { |n| n.resolve!(auto: true); auto_resolved += 1 }

    { hit_count: results.size, created: created, updated: updated, auto_resolved: auto_resolved, error: nil }
  end

  def overall_status(total:, failed:)
    return "failed"  if failed == total
    return "partial" if failed.positive?

    "success"
  end

  # meta 只留規則命中/建立/更新/解除的聚合數字與錯誤 class 名稱，不含任何個資。
  def safe_meta(per_rule)
    per_rule.transform_values { |v| v.is_a?(Hash) ? v.stringify_keys : v }
  end
end

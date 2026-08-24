# frozen_string_literal: true

require Rails.root.join("lib/notifications_maintenance_lock") if defined?(Rails)

# Orchestrator for the fixed notification rule categories (8 existing +
# 5 livestream-ops rules added in the 營運提醒中心 redesign; event_attention
# was retired from RULES — superseded by livestream_preparation's T-3/T-1
# checklist and livestream_performance_drop's D+1/D+3 comparison, see those
# classes' comments). Each rule class
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
    "customer_runout"        => "NotificationRules::CustomerRunout",
    "customer_overdue"       => "NotificationRules::CustomerOverdue",
    "high_spender_no_second" => "NotificationRules::HighSpenderNoSecond",
    "vip_silent"             => "NotificationRules::VipSilent",
    "product_attention"      => "NotificationRules::ProductAttention",
    "promotion_opportunity"  => "NotificationRules::PromotionOpportunity",
    "livestream_schedule_gap"     => "NotificationRules::LivestreamScheduleGap",
    "livestream_preparation"      => "NotificationRules::LivestreamPreparation",
    "livestream_day_attention"    => "NotificationRules::LivestreamDayAttention",
    "livestream_performance_drop" => "NotificationRules::LivestreamPerformanceDrop",
    "livestream_review_due"       => "NotificationRules::LivestreamReviewDue"
  }.freeze

  def self.run_all
    new.run(RULES.keys)
  end

  def self.run_rule(category)
    raise ArgumentError, "unknown rule category: #{category.inspect}" unless RULES.key?(category)

    new.run([category])
  end

  def self.dry_run(categories)
    new.dry_run(categories)
  end

  # Read-only preview: calls each rule's .call (rules only ever query, never
  # write — writes live exclusively in upsert_and_resolve! below) and diffs
  # the results against currently-open notifications, WITHOUT creating a
  # SyncRun row, WITHOUT touching the advisory lock, and WITHOUT calling
  # Notification.create!/update!/resolve! anywhere in this path.
  def dry_run(categories)
    per_rule = {}
    categories.each { |category| per_rule[category] = dry_run_one_rule(category) }
    { per_rule: per_rule }
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

  # ── Dry run (read-only preview) ────────────────────────────────────

  def dry_run_one_rule(category)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    klass = RULES.fetch(category).constantize
    results = klass.call
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)
    dry_run_diff(category, results, query_seconds: elapsed)
  rescue StandardError => e
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)
    { matched_subjects: 0, cards_to_create: 0, cards_to_update: 0, cards_to_resolve: 0,
      severity_distribution: {}, metadata_bytes_estimate: 0, query_seconds: elapsed, error: e.class.name }
  end

  # Same dedup_key matching logic as upsert_and_resolve!, but only counts —
  # never calls create!/update!/resolve!, so it cannot mutate the table.
  def dry_run_diff(category, results, query_seconds:)
    seen_keys = results.map { |r| r.fetch(:deduplication_key) }
    existing_open_keys = Notification.open_status.where(category: category).pluck(:deduplication_key)

    {
      matched_subjects: results.size,
      cards_to_create: (seen_keys - existing_open_keys).size,
      cards_to_update: (seen_keys & existing_open_keys).size,
      cards_to_resolve: (existing_open_keys - seen_keys).size,
      severity_distribution: results.group_by { |r| r[:severity] }.transform_values(&:size),
      metadata_bytes_estimate: results.sum { |r| (r[:metadata] || {}).to_json.bytesize },
      query_seconds: query_seconds,
      error: nil
    }
  end

  # ── Upsert / auto-resolve (fatigue-control core) ──────────────────

  def upsert_and_resolve!(category, results)
    now = Time.current
    seen_keys = []
    created = 0
    updated = 0
    reopened = 0

    results.each do |r|
      dedup_key = r.fetch(:deduplication_key)
      seen_keys << dedup_key
      priority = r[:priority] || severity_to_priority(r.fetch(:severity))

      existing = Notification.active.find_by(deduplication_key: dedup_key)
      if existing
        existing.update!(last_detected_at: now, title: r[:title], message: r[:message],
                         severity: r[:severity], priority: priority, metadata: r[:metadata] || {},
                         impact_summary: r[:impact_summary], recommended_action: r[:recommended_action],
                         occurrence_count: existing.occurrence_count + 1)
        # 條件在 pending_verification 期間仍持續發生，代表剛才的處理沒有真的
        # 解決問題——退回 in_progress，不能悄悄留著假裝在等驗證。
        if existing.status == "pending_verification"
          existing.reopen_after_failed_verification!
          reopened += 1
        end
        updated += 1
      else
        prior = Notification.where(deduplication_key: dedup_key, status: %w[resolved dismissed])
                            .order(created_at: :desc).first
        occurrence = prior ? prior.occurrence_count + 1 : 1
        metadata = (r[:metadata] || {}).dup
        metadata["recurred_after_resolution"] = true if prior&.status == "resolved"

        Notification.create!(
          notification_key: r.fetch(:notification_key), kind: r.fetch(:kind), category: category,
          severity: r.fetch(:severity), priority: priority, title: r.fetch(:title), message: r[:message],
          subject_type: r[:subject_type], subject_id: r[:subject_id], metadata: metadata,
          impact_summary: r[:impact_summary], recommended_action: r[:recommended_action],
          deduplication_key: dedup_key, status: initial_status(priority),
          occurrence_count: occurrence, reopened_count: prior ? prior.reopened_count + 1 : 0,
          first_detected_at: now, last_detected_at: now
        )
        created += 1
      end
    end

    stale = Notification.active.where(category: category)
    stale = stale.where.not(deduplication_key: seen_keys) if seen_keys.any?
    auto_resolved = 0
    stale.find_each { |n| n.auto_resolve!; auto_resolved += 1 }

    { hit_count: results.size, created: created, updated: updated, auto_resolved: auto_resolved,
      reopened: reopened, error: nil }
  end

  SEVERITY_TO_PRIORITY = { "critical" => "P0", "warning" => "P1", "opportunity" => "P2", "info" => "P3" }.freeze

  def severity_to_priority(severity)
    SEVERITY_TO_PRIORITY.fetch(severity, "P2")
  end

  # P0/P1 一產生就要有人管——直接落在 pending_assignment 提示「這張需要指派」；
  # P2/P3 先進 detected，優先權沒那麼急，可以晚一點再分診。
  def initial_status(priority)
    %w[P0 P1].include?(priority) ? "pending_assignment" : "detected"
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

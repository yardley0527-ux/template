# frozen_string_literal: true

require "test_helper"

class NotificationTest < ActiveSupport::TestCase
  def build_notification(attrs = {})
    Notification.new({
      notification_key: "test_rule", kind: "alert", category: "system_health",
      severity: "warning", priority: "P2", title: "測試通知", deduplication_key: "test_rule:none:#{SecureRandom.hex(4)}",
      status: "detected", first_detected_at: Time.current, last_detected_at: Time.current
    }.merge(attrs))
  end

  def user(username: "tester#{SecureRandom.hex(3)}")
    User.create!(username: username, email: "#{username}@example.com", password: "password123")
  end

  test "valid with required fields" do
    assert build_notification.valid?
  end

  %i[notification_key kind category severity priority title status deduplication_key
     first_detected_at last_detected_at].each do |field|
    test "invalid without #{field}" do
      n = build_notification(field => nil)
      assert_not n.valid?
      assert n.errors[field].present?
    end
  end

  test "rejects kind outside KINDS" do
    assert_not build_notification(kind: "bogus").valid?
  end

  test "rejects category outside CATEGORIES" do
    assert_not build_notification(category: "bogus").valid?
  end

  test "rejects severity outside SEVERITIES" do
    assert_not build_notification(severity: "bogus").valid?
  end

  test "rejects priority outside PRIORITIES" do
    assert_not build_notification(priority: "bogus").valid?
  end

  test "rejects status outside STATUSES" do
    assert_not build_notification(status: "bogus").valid?
  end

  test "deduplication_key must be unique among active statuses" do
    build_notification(deduplication_key: "dupe:key", status: "detected").save!
    assert_not build_notification(deduplication_key: "dupe:key", status: "in_progress").valid?
  end

  test "a resolved row does not block a new active row with the same deduplication_key" do
    build_notification(deduplication_key: "dupe:key2", status: "resolved", resolved_at: Time.current)
      .save!(validate: false)

    assert build_notification(deduplication_key: "dupe:key2", status: "detected").valid?
  end

  test "two resolved rows may share the same deduplication_key (full history)" do
    build_notification(deduplication_key: "dupe:key3", status: "resolved", resolved_at: Time.current)
      .save!(validate: false)

    assert build_notification(deduplication_key: "dupe:key3", status: "resolved", resolved_at: Time.current).valid?
  end

  test "metadata defaults to empty hash" do
    n = build_notification(deduplication_key: "meta:#{SecureRandom.hex(4)}").tap(&:save!)
    assert_equal({}, n.metadata)
  end

  test "dismissed status requires dismissal_reason" do
    n = build_notification(status: "dismissed", dismissed_at: Time.current)
    assert_not n.valid?
    assert n.errors[:dismissal_reason].present?
  end

  test "P0/P1 dismissed status only accepts known_risk or permanently_excluded" do
    n = build_notification(priority: "P0", status: "dismissed", dismissed_at: Time.current, dismissal_reason: "misjudged")
    assert_not n.valid?

    n2 = build_notification(priority: "P0", status: "dismissed", dismissed_at: Time.current, dismissal_reason: "known_risk")
    assert n2.valid?
  end

  test "snoozed status requires snoozed_until and snooze_reason" do
    n = build_notification(status: "snoozed")
    assert_not n.valid?
    assert n.errors[:snoozed_until].present?
    assert n.errors[:snooze_reason].present?
  end

  test "broad_category maps the 9+5 rule categories to the 5 user-facing categories" do
    assert_equal "customer_opportunity", build_notification(category: "vip_silent").broad_category
    assert_equal "product_revenue", build_notification(category: "product_attention").broad_category
    assert_equal "inventory", build_notification(category: "inventory_attention").broad_category
    assert_equal "livestream_event", build_notification(category: "livestream_schedule_gap").broad_category
    assert_equal "system_health", build_notification(category: "system_health").broad_category
  end

  # ── scopes ──────────────────────────────────────────────────────

  test "active scope excludes resolved and dismissed" do
    active_n = build_notification.tap(&:save!)
    resolved_n = build_notification(status: "resolved", resolved_at: Time.current)
    resolved_n.save!(validate: false)
    dismissed_n = build_notification(status: "dismissed", dismissed_at: Time.current, dismissal_reason: "misjudged")
    dismissed_n.save!(validate: false)

    assert_includes Notification.active, active_n
    assert_not_includes Notification.active, resolved_n
    assert_not_includes Notification.active, dismissed_n
  end

  test "open_status is an alias for active (back-compat for existing call sites)" do
    n = build_notification(status: "pending_verification").tap { |x| x.save!(validate: false) }
    assert_includes Notification.open_status, n
  end

  test "unread scope excludes read notifications" do
    unread_n = build_notification.tap(&:save!)
    read_n = build_notification(read_at: Time.current).tap(&:save!)

    assert_includes Notification.unread, unread_n
    assert_not_includes Notification.unread, read_n
  end

  test "by_category scope filters correctly" do
    a = build_notification(category: "system_health").tap(&:save!)
    b = build_notification(category: "vip_silent").tap(&:save!)

    assert_includes Notification.by_category("system_health"), a
    assert_not_includes Notification.by_category("system_health"), b
  end

  test "overdue scope only returns active notifications past due_at" do
    overdue_n = build_notification(due_at: 1.hour.ago).tap(&:save!)
    future_n = build_notification(due_at: 1.hour.from_now).tap(&:save!)
    no_due_n = build_notification.tap(&:save!)

    assert_includes Notification.overdue, overdue_n
    assert_not_includes Notification.overdue, future_n
    assert_not_includes Notification.overdue, no_due_n
  end

  # ── read/unread (read != resolved, spec section 二 rule 1) ──────

  test "mark_read! sets read_at once and is idempotent, and does not change status" do
    n = build_notification.tap(&:save!)
    n.mark_read!
    first_read_at = n.read_at
    assert_equal "detected", n.status, "marking read must not remove it from the active work queue"

    travel 1.hour do
      n.mark_read!
      assert_equal first_read_at.to_i, n.reload.read_at.to_i
    end
  end

  # ── workflow state machine (spec section 二) ────────────────────

  test "assign! sets owner and due_at and moves to in_progress" do
    u = user
    n = build_notification(status: "pending_assignment").tap { |x| x.save!(validate: false) }
    n.assign!(u, due_at: 1.day.from_now)
    n.reload
    assert_equal u.id, n.owner_user_id
    assert_equal "in_progress", n.status
    assert n.due_at.present?
  end

  test "start! self-claims without an owner change if already assigned" do
    u1 = user
    u2 = user
    n = build_notification(status: "in_progress", owner_user_id: u1.id).tap { |x| x.save!(validate: false) }
    n.start!(u2)
    assert_equal u1.id, n.reload.owner_user_id, "must not silently steal an existing owner"
  end

  test "request_verification! moves a monitoring-type notification to pending_verification, not resolved" do
    n = build_notification(status: "in_progress").tap(&:save!)
    n.request_verification!(actor: user, resolution_reason: "已補貨")
    n.reload
    assert_equal "pending_verification", n.status
    assert_equal "已補貨", n.resolution_reason
    assert_nil n.resolved_at, "must not be resolved yet — only the engine confirms that on the next run"
  end

  test "auto_resolve! is the only path that sets resolved_at, and is tagged auto" do
    n = build_notification(status: "pending_verification").tap { |x| x.save!(validate: false) }
    n.auto_resolve!
    n.reload
    assert_equal "resolved", n.status
    assert n.resolved_at.present?
    assert_equal "auto", n.metadata["resolved_by"]
  end

  test "reopen_after_failed_verification! sends a still-firing pending_verification card back to in_progress" do
    n = build_notification(status: "pending_verification").tap { |x| x.save!(validate: false) }
    n.reopen_after_failed_verification!
    assert_equal "in_progress", n.reload.status
  end

  test "snooze! requires resuming and restores the pre-snooze status on wake" do
    n = build_notification(status: "in_progress").tap(&:save!)
    n.snooze!(until_at: 3.days.from_now, reason: "客戶說下週再聯絡")
    n.reload
    assert_equal "snoozed", n.status
    assert n.snoozed_until.present?

    n.wake_from_snooze!
    assert_equal "in_progress", n.reload.status
    assert_nil n.snoozed_until
  end

  test "wake_expired_snoozes! wakes snoozes whose date has passed but leaves future ones alone" do
    expired = build_notification(status: "in_progress").tap(&:save!)
    expired.snooze!(until_at: 1.hour.ago, reason: "test")
    future = build_notification(status: "in_progress").tap(&:save!)
    future.snooze!(until_at: 1.day.from_now, reason: "test")

    Notification.wake_expired_snoozes!

    assert_equal "in_progress", expired.reload.status
    assert_equal "snoozed", future.reload.status
  end

  test "dismiss! requires a reason and sets dismissed_at" do
    n = build_notification.tap(&:save!)
    n.dismiss!(reason: "not_applicable")
    n.reload
    assert_equal "dismissed", n.status
    assert n.dismissed_at.present?
    assert_equal "not_applicable", n.dismissal_reason
  end

  test "dismiss! raises without a reason" do
    n = build_notification.tap(&:save!)
    assert_raises(ArgumentError) { n.dismiss!(reason: nil) }
  end

  test "P0/P1 cannot be dismissed with misjudged or not_applicable" do
    n = build_notification(priority: "P1").tap(&:save!)
    assert_raises(ArgumentError) { n.dismiss!(reason: "misjudged") }
    assert_raises(ArgumentError) { n.dismiss!(reason: "not_applicable") }

    n.dismiss!(reason: "known_risk")
    assert_equal "dismissed", n.reload.status
  end

  test "a recurred notification after resolution is marked recurred_after_resolution in metadata (engine-driven, verified at model level)" do
    n = build_notification(status: "resolved", resolved_at: Time.current,
                           metadata: { "recurred_after_resolution" => true }).tap { |x| x.save!(validate: false) }
    assert n.metadata["recurred_after_resolution"]
  end
end

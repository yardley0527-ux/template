# frozen_string_literal: true

require "test_helper"

class NotificationTest < ActiveSupport::TestCase
  def build_notification(attrs = {})
    Notification.new({
      notification_key: "test_rule", kind: "alert", category: "system_health",
      severity: "warning", title: "測試通知", deduplication_key: "test_rule:none:#{SecureRandom.hex(4)}",
      status: "open", first_detected_at: Time.current, last_detected_at: Time.current
    }.merge(attrs))
  end

  test "valid with required fields" do
    assert build_notification.valid?
  end

  %i[notification_key kind category severity title status deduplication_key
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

  test "rejects status outside STATUSES" do
    assert_not build_notification(status: "bogus").valid?
  end

  test "deduplication_key must be unique" do
    build_notification(deduplication_key: "dupe:key").save!
    assert_not build_notification(deduplication_key: "dupe:key").valid?
  end

  test "metadata defaults to empty hash" do
    n = Notification.create!(notification_key: "x", kind: "alert", category: "system_health",
                             severity: "info", title: "t", deduplication_key: "x:#{SecureRandom.hex(4)}",
                             status: "open", first_detected_at: Time.current, last_detected_at: Time.current)
    assert_equal({}, n.metadata)
  end

  # ── scopes ──────────────────────────────────────────────────────

  test "open_status scope only returns open notifications" do
    open_n = build_notification.tap(&:save!)
    resolved_n = build_notification(status: "resolved", resolved_at: Time.current)
    resolved_n.save!(validate: false) # bypass to set status directly without going through resolve!

    assert_includes Notification.open_status, open_n
    assert_not_includes Notification.open_status, resolved_n
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

  test "critical scope filters by severity" do
    c = build_notification(severity: "critical").tap(&:save!)
    w = build_notification(severity: "warning").tap(&:save!)

    assert_includes Notification.critical, c
    assert_not_includes Notification.critical, w
  end

  # ── state transitions ──────────────────────────────────────────

  test "mark_read! sets read_at once and is idempotent" do
    n = build_notification.tap(&:save!)
    assert_not n.read?

    n.mark_read!
    first_read_at = n.read_at
    assert n.read?

    travel 1.hour do
      n.mark_read!
      assert_equal first_read_at.to_i, n.reload.read_at.to_i, "second mark_read! must not bump read_at"
    end
  end

  test "resolve! sets status and resolved_at, tags manual by default" do
    n = build_notification.tap(&:save!)
    n.resolve!
    n.reload
    assert_equal "resolved", n.status
    assert n.resolved_at.present?
    assert_equal "manual", n.metadata["resolved_by"]
  end

  test "resolve! with auto: true tags auto" do
    n = build_notification.tap(&:save!)
    n.resolve!(auto: true)
    assert_equal "auto", n.reload.metadata["resolved_by"]
  end

  test "dismiss! sets status and dismissed_at" do
    n = build_notification.tap(&:save!)
    n.dismiss!
    n.reload
    assert_equal "dismissed", n.status
    assert n.dismissed_at.present?
  end
end

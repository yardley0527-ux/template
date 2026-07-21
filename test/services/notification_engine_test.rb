# frozen_string_literal: true

require "test_helper"

class NotificationEngineTest < ActiveSupport::TestCase
  # 用假規則類別取代真規則，隔離測試 engine 本身的 upsert/resolve/lock/SyncRun 行為，
  # 不依賴任何真實業務資料。
  class StubRule
    def self.results=(v); @results = v; end
    def self.call; @results || []; end
  end

  class FailingRule
    def self.call; raise ArgumentError, "boom with customer@example.com"; end
  end

  def with_stub_rules(map)
    original = NotificationEngine::RULES
    NotificationEngine.send(:remove_const, :RULES)
    NotificationEngine.const_set(:RULES, map.transform_values(&:name).freeze)
    yield
  ensure
    NotificationEngine.send(:remove_const, :RULES)
    NotificationEngine.const_set(:RULES, original)
  end

  def result(key:, dedup:, severity: "info", kind: "alert", title: "t", subject_type: "x", subject_id: "1")
    { notification_key: key, kind: kind, severity: severity, title: title, message: "m",
      subject_type: subject_type, subject_id: subject_id, metadata: {}, deduplication_key: dedup }
  end

  test "run_all creates one notification per rule result and records a success SyncRun" do
    with_stub_rules("system_health" => StubRule) do
      StubRule.results = [result(key: "r1", dedup: "r1:x:1")]
      out = NotificationEngine.new.run(["system_health"])

      assert_equal "success", out[:status]
      assert_equal 1, out[:per_rule]["system_health"][:created]
      assert_equal 1, Notification.where(deduplication_key: "r1:x:1", status: "open").count
      assert_equal "success", SyncRun.find(out[:sync_run_id]).status
      assert_equal "notifications", SyncRun.find(out[:sync_run_id]).source
    end
  end

  test "re-running with the same result updates last_detected_at instead of duplicating" do
    with_stub_rules("system_health" => StubRule) do
      StubRule.results = [result(key: "r1", dedup: "r1:x:1")]
      NotificationEngine.new.run(["system_health"])
      n = Notification.find_by(deduplication_key: "r1:x:1")
      first_detected = n.first_detected_at

      travel 1.hour do
        out = NotificationEngine.new.run(["system_health"])
        assert_equal 0, out[:per_rule]["system_health"][:created]
        assert_equal 1, out[:per_rule]["system_health"][:updated]
      end

      n.reload
      assert_equal 1, Notification.where(deduplication_key: "r1:x:1").count, "must not duplicate"
      assert_equal first_detected.to_i, n.first_detected_at.to_i, "first_detected_at must not move"
      assert n.last_detected_at > first_detected, "last_detected_at must advance"
    end
  end

  test "a condition that stops firing is auto-resolved" do
    with_stub_rules("system_health" => StubRule) do
      StubRule.results = [result(key: "r1", dedup: "r1:x:1")]
      NotificationEngine.new.run(["system_health"])

      StubRule.results = []
      out = NotificationEngine.new.run(["system_health"])

      assert_equal 1, out[:per_rule]["system_health"][:auto_resolved]
      n = Notification.find_by(deduplication_key: "r1:x:1")
      assert_equal "resolved", n.status
      assert_equal "auto", n.metadata["resolved_by"]
    end
  end

  test "a recurring condition after auto-resolve starts a fresh cycle, not reopening the old row" do
    with_stub_rules("system_health" => StubRule) do
      StubRule.results = [result(key: "r1", dedup: "r1:x:1")]
      NotificationEngine.new.run(["system_health"])
      old = Notification.find_by(deduplication_key: "r1:x:1")

      StubRule.results = []
      NotificationEngine.new.run(["system_health"]) # resolves it

      travel 1.day do
        StubRule.results = [result(key: "r1", dedup: "r1:x:1")]
        out = NotificationEngine.new.run(["system_health"])
        assert_equal 1, out[:per_rule]["system_health"][:created]
      end

      assert_equal "resolved", old.reload.status, "old cycle stays resolved, untouched"
      new_open = Notification.find_by(deduplication_key: "r1:x:1", status: "open")
      assert new_open.present?
      assert_not_equal old.id, new_open.id
      assert new_open.first_detected_at > old.first_detected_at
    end
  end

  test "auto-resolve only touches this run's category, not other categories' open notifications" do
    with_stub_rules("system_health" => StubRule, "vip_silent" => StubRule) do
      StubRule.results = [result(key: "r1", dedup: "vip:1")]
      NotificationEngine.new.run(["vip_silent"])
      untouched = Notification.find_by(deduplication_key: "vip:1")

      StubRule.results = []
      NotificationEngine.new.run(["system_health"])

      assert_equal "open", untouched.reload.status
    end
  end

  test "one rule failing does not abort the others (per-rule rescue)" do
    with_stub_rules("system_health" => StubRule, "vip_silent" => FailingRule) do
      StubRule.results = [result(key: "r1", dedup: "ok:1")]
      out = NotificationEngine.new.run(%w[system_health vip_silent])

      assert_equal "partial", out[:status]
      assert_equal 1, out[:per_rule]["system_health"][:created]
      assert_equal "ArgumentError", out[:per_rule]["vip_silent"][:error]
      assert Notification.exists?(deduplication_key: "ok:1")
    end
  end

  test "all rules failing marks the SyncRun failed" do
    with_stub_rules("system_health" => FailingRule) do
      out = NotificationEngine.new.run(["system_health"])
      assert_equal "failed", out[:status]
    end
  end

  test "error messages (which may embed PII) never reach SyncRun meta — only the exception class" do
    with_stub_rules("system_health" => FailingRule) do
      out = NotificationEngine.new.run(["system_health"])
      meta_json = SyncRun.find(out[:sync_run_id]).meta.to_json
      assert_not_includes meta_json, "customer@example.com"
      assert_includes meta_json, "ArgumentError"
    end
  end

  test "run_rule rejects an unknown category" do
    assert_raises(ArgumentError) { NotificationEngine.run_rule("not_a_real_category") }
  end

  # ── advisory lock ────────────────────────────────────────────────

  test "a concurrent run aborts without writing when the lock is held elsewhere" do
    with_stub_rules("system_health" => StubRule) do
      StubRule.results = [result(key: "r1", dedup: "locked:1")]

      db_config = ActiveRecord::Base.connection_db_config.configuration_hash
      other = PG.connect(dbname: db_config[:database], host: db_config[:host],
                         port: db_config[:port], user: db_config[:username], password: db_config[:password])
      other.exec("SELECT pg_advisory_lock(hashtext('notifications_generate'))")
      begin
        out = NotificationEngine.new.run(["system_health"])
        assert out[:aborted]
        assert_not Notification.exists?(deduplication_key: "locked:1")
      ensure
        other.exec("SELECT pg_advisory_unlock(hashtext('notifications_generate'))")
        other.close
      end
    end
  end
end

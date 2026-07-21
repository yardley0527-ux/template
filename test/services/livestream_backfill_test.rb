# frozen_string_literal: true

require "test_helper"

class LivestreamBackfillTest < ActiveSupport::TestCase
  KEYS = %w[alpha beta].freeze

  setup do
    KEYS.each { |k| CrmProduct.create!(key: k, label: k.upcase, status: "confirmed") }
    @out = StringIO.new
  end

  # ── 測試用小型 YAML ──────────────────────────────────────────────────────

  def write_yaml(entries)
    path = Rails.root.join("tmp", "backfill_test_#{SecureRandom.hex(4)}.yml")
    File.write(path, YAML.dump(entries.map { |e| deep_stringify(e) }))
    path
  end

  def deep_stringify(obj)
    case obj
    when Hash then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
    when Array then obj.map { |v| deep_stringify(v) }
    else obj
    end
  end

  def entry(date:, original_date: nil, title: "品牌之夜：測試", keys: ["alpha"],
            orders: { value: 10, source: "consensus", confidence: "probable", conflict_note: nil },
            revenue: { value: 1000, source: "consensus", confidence: "probable", conflict_note: nil },
            raw: nil, unmapped: [])
    raw ||= { all_events: { note: "測試", orders: orders[:value], revenue: revenue[:value] },
              live_events: { name: "測試", products: "測試", orders: orders[:value], revenue: revenue[:value] },
              calendar: nil }
    { date: date, original_date: original_date, title: title, product_keys: keys,
      unmapped_products: unmapped, reported_orders: orders, reported_revenue: revenue, raw: raw }
  end

  def service(entries)
    LivestreamBackfill.new(yaml_path: write_yaml(entries), io: @out, expected_count: entries.size)
  end

  # ── migration / schema（測試 1）─────────────────────────────────────────

  test "migration adds plan B columns with expected defaults and precision" do
    ls = Livestream.new(date: Date.new(2030, 1, 1))
    assert_equal 3, ls.window_days
    assert_equal 0, ls.total_buyers
    assert_equal 0, ls.new_buyers
    assert_nil ls.title
    assert_nil ls.reported_orders
    assert_nil ls.reported_revenue
    assert_nil ls.stats_refreshed_at

    col = Livestream.columns_hash["reported_revenue"]
    assert_equal 14, col.precision
    assert_equal 2, col.scale
    # 既有 registry 欄位未被動到
    assert Livestream.column_names.include?("analysis_note")
    assert Livestream.column_names.include?("level_black_count")
  end

  test "sync_run accepts livestream_backfill source" do
    run = SyncRun.new(source: "livestream_backfill", status: "success", started_at: Time.current)
    assert run.valid?
  end

  # ── preview（測試 3、4 的行為版；45 場版在 reconciliation_yml_test）────

  test "preview writes nothing to db" do
    Livestream.create!(date: Date.new(2030, 1, 1))
    entries = [entry(date: Date.new(2030, 1, 1))]
    csv_path = Rails.root.join("tmp", "backfill_preview_test.csv")

    assert_no_difference ["SyncRun.count"] do
      service(entries).preview(csv_path: csv_path)
    end
    record = Livestream.unscoped.find_by(date: Date.new(2030, 1, 1))
    assert_nil record.title
    assert_empty record.product_keys

    lines = CSV.read(csv_path)
    assert_equal 2, lines.size # header + 1
    assert_includes lines[1], "品牌之夜：測試"
  end

  # ── apply（測試 5、6、7、8、15）────────────────────────────────────────

  test "apply backfills fields and is idempotent" do
    Livestream.create!(date: Date.new(2030, 1, 1))
    entries = [entry(date: Date.new(2030, 1, 1))]

    result = service(entries).apply
    assert_equal 1, result[:changed]

    record = Livestream.unscoped.find_by(date: Date.new(2030, 1, 1))
    assert_equal "品牌之夜：測試", record.title
    assert_equal ["alpha"], record.product_keys
    assert_equal 10, record.reported_orders
    assert_equal 1000.to_d, record.reported_revenue

    # 冪等：第二次無變更、不建立新 snapshot
    assert_no_difference "SyncRun.count" do
      second = service(entries).apply
      assert_equal 0, second[:changed]
      assert_nil second[:sync_run]
    end
  end

  test "apply moves corrected date when target is free" do
    Livestream.create!(date: Date.new(2030, 1, 2))
    entries = [entry(date: Date.new(2030, 1, 1), original_date: Date.new(2030, 1, 2))]

    service(entries).apply
    assert Livestream.unscoped.exists?(date: Date.new(2030, 1, 1))
    assert_not Livestream.unscoped.exists?(date: Date.new(2030, 1, 2))
  end

  test "apply aborts with zero writes when date target already exists" do
    Livestream.create!(date: Date.new(2030, 1, 2), title: "原始")
    Livestream.create!(date: Date.new(2030, 1, 1))
    entries = [
      entry(date: Date.new(2030, 1, 1), original_date: Date.new(2030, 1, 2)),
      entry(date: Date.new(2030, 1, 3))
    ]
    Livestream.create!(date: Date.new(2030, 1, 3))

    assert_no_difference "SyncRun.count" do
      assert_raises(LivestreamBackfill::ValidationError) { service(entries).apply }
    end
    assert_equal "原始", Livestream.unscoped.find_by(date: Date.new(2030, 1, 2)).title
    assert_nil Livestream.unscoped.find_by(date: Date.new(2030, 1, 3)).title # 另一場也零寫入
  end

  test "apply aborts when product key missing from crm_products" do
    Livestream.create!(date: Date.new(2030, 1, 1))
    entries = [entry(date: Date.new(2030, 1, 1), keys: ["nonexistent_key"])]

    err = assert_raises(LivestreamBackfill::ValidationError) { service(entries).apply }
    assert_match "nonexistent_key", err.message
    assert_nil Livestream.unscoped.find_by(date: Date.new(2030, 1, 1)).title
  end

  test "apply aborts when record for entry is missing" do
    entries = [entry(date: Date.new(2030, 1, 1))]
    assert_raises(LivestreamBackfill::ValidationError) { service(entries).apply }
  end

  test "yaml validation rejects conflicting reported value without confirmed confidence" do
    Livestream.create!(date: Date.new(2030, 1, 1))
    conflicted = entry(
      date: Date.new(2030, 1, 1),
      orders: { value: 10, source: "all_events", confidence: "probable", conflict_note: "AE 10 vs LE 12" },
      raw: { all_events: { note: "x", orders: 10, revenue: 1000 },
             live_events: { name: "x", products: "x", orders: 12, revenue: 1000 },
             calendar: nil }
    )
    err = assert_raises(LivestreamBackfill::ValidationError) { service([conflicted]).apply }
    assert_match "未經人工核對不得回填", err.message
  end

  test "yaml validation allows confirmed value on conflict (shopline_backend)" do
    Livestream.create!(date: Date.new(2030, 1, 1))
    resolved = entry(
      date: Date.new(2030, 1, 1),
      orders: { value: 12, source: "shopline_backend", confidence: "confirmed", conflict_note: "AE 10 vs LE 12，後台核對=12" },
      raw: { all_events: { note: "x", orders: 10, revenue: 1000 },
             live_events: { name: "x", products: "x", orders: 12, revenue: 1000 },
             calendar: nil }
    )
    service([resolved]).apply
    assert_equal 12, Livestream.unscoped.find_by(date: Date.new(2030, 1, 1)).reported_orders
  end

  test "snapshot contains only backfill columns for changed records" do
    Livestream.create!(date: Date.new(2030, 1, 1))
    result = service([entry(date: Date.new(2030, 1, 1))]).apply

    snapshot = result[:sync_run].reload.meta["snapshot"]
    assert_equal 1, snapshot.size
    item = snapshot.first
    assert_equal LivestreamBackfill::BACKFILL_COLUMNS.sort, item["before"].keys.sort
    assert_equal LivestreamBackfill::BACKFILL_COLUMNS.sort, item["after"].keys.sort
    assert_equal "success", result[:sync_run].status
  end

  # ── transaction 原子性 ──────────────────────────────────────────────────

  class MidApplyFailure < StandardError; end

  # 測試替身：第二場寫入時爆炸，驗證整批 rollback
  class FailingBackfill < LivestreamBackfill
    def apply_row!(row)
      raise MidApplyFailure, "boom at #{row.after['date']}" if row.after["date"] == "2030-01-02"

      super
    end
  end

  test "mid-apply failure rolls back all updates and leaves no usable snapshot" do
    Livestream.create!(date: Date.new(2030, 1, 1))
    Livestream.create!(date: Date.new(2030, 1, 2))
    entries = [entry(date: Date.new(2030, 1, 1)), entry(date: Date.new(2030, 1, 2))]
    svc = FailingBackfill.new(yaml_path: write_yaml(entries), io: @out, expected_count: 2)

    assert_raises(MidApplyFailure) { svc.apply }

    # 兩場全部 rollback（含爆炸前已寫入的第一場）
    assert_nil Livestream.unscoped.find_by(date: Date.new(2030, 1, 1)).title
    assert_nil Livestream.unscoped.find_by(date: Date.new(2030, 1, 2)).title
    # 不留 success/running SyncRun；失敗記錄無 snapshot、不可被 revert 使用
    assert_empty SyncRun.where(source: "livestream_backfill", status: %w[success running])
    failed = SyncRun.where(source: "livestream_backfill", status: "failed").sole
    assert_nil failed.meta["snapshot"]
    assert_match "MidApplyFailure", failed.error_messages.first
    assert_raises(LivestreamBackfill::ValidationError) { svc.revert(confirm: true) }
  end

  test "lookup prefers original_date record over already-backfilled date" do
    # 只有 original_date 有場次 → 走日期修正
    Livestream.create!(date: Date.new(2030, 1, 2))
    svc = service([entry(date: Date.new(2030, 1, 1), original_date: Date.new(2030, 1, 2))])
    svc.apply
    assert Livestream.unscoped.exists?(date: Date.new(2030, 1, 1))

    # 已回填後（只剩 date 有場次）→ 以 date 對應、no-op
    second = service([entry(date: Date.new(2030, 1, 1), original_date: Date.new(2030, 1, 2))]).apply
    assert_equal 0, second[:changed]
  end

  # ── revert（測試 16、17、18）───────────────────────────────────────────

  test "revert restores snapshot columns" do
    Livestream.create!(date: Date.new(2030, 1, 2))
    entries = [entry(date: Date.new(2030, 1, 1), original_date: Date.new(2030, 1, 2))]
    svc = service(entries)
    svc.apply

    # 預設 dry-run 不寫入
    result = svc.revert
    assert result[:dry_run]
    assert Livestream.unscoped.exists?(date: Date.new(2030, 1, 1))

    svc.revert(confirm: true)
    record = Livestream.unscoped.find_by(date: Date.new(2030, 1, 2))
    assert record, "date 應還原"
    assert_nil record.title
    assert_empty record.product_keys
    assert_nil record.reported_orders
  end

  test "revert skips drifted record by default and overwrites with force" do
    Livestream.create!(date: Date.new(2030, 1, 1))
    svc = service([entry(date: Date.new(2030, 1, 1))])
    svc.apply

    # 模擬使用者後續修改
    Livestream.unscoped.find_by(date: Date.new(2030, 1, 1)).update!(title: "使用者改過")

    result = svc.revert(confirm: true)
    assert_equal :skip, result[:plan].first[:action]
    assert_equal "使用者改過", Livestream.unscoped.find_by(date: Date.new(2030, 1, 1)).title

    svc.revert(confirm: true, force: true)
    assert_nil Livestream.unscoped.find_by(date: Date.new(2030, 1, 1)).title
  end

  test "revert aborts without a valid snapshot" do
    assert_raises(LivestreamBackfill::ValidationError) { service([]).revert }
    SyncRun.create!(source: "livestream_backfill", status: "failed", started_at: Time.current)
    assert_raises(LivestreamBackfill::ValidationError) { service([]).revert }
  end

  test "revert with explicit sync_run_id uses that snapshot" do
    Livestream.create!(date: Date.new(2030, 1, 1))
    svc = service([entry(date: Date.new(2030, 1, 1))])
    run = svc.apply[:sync_run]

    result = svc.revert(sync_run_id: run.id, confirm: true)
    assert_not result[:dry_run]
    assert_nil Livestream.unscoped.find_by(date: Date.new(2030, 1, 1)).title
    assert_raises(LivestreamBackfill::ValidationError) { svc.revert(sync_run_id: run.id + 999) }
  end

  # ── PR1 安全補強：original_date 交叉驗證 ─────────────────────────────────

  test "yaml validation rejects duplicate original_date across entries" do
    entries = [
      entry(date: Date.new(2030, 1, 1), original_date: Date.new(2030, 1, 10)),
      entry(date: Date.new(2030, 1, 2), original_date: Date.new(2030, 1, 10))
    ]
    err = assert_raises(LivestreamBackfill::ValidationError) { service(entries).preview }
    assert_match "original_date 有重複", err.message
  end

  test "yaml validation rejects original_date overlapping another entry's date" do
    entries = [
      entry(date: Date.new(2030, 1, 5)),
      entry(date: Date.new(2030, 1, 1), original_date: Date.new(2030, 1, 5))
    ]
    err = assert_raises(LivestreamBackfill::ValidationError) { service(entries).preview }
    assert_match "original_date 與其他場次的 date 重疊", err.message
  end

  # ── PR1 安全補強：apply advisory lock ────────────────────────────────────

  test "apply aborts when another apply holds the advisory lock" do
    Livestream.create!(date: Date.new(2030, 1, 1))
    svc = service([entry(date: Date.new(2030, 1, 1))])

    other_conn = ActiveRecord::Base.connection_pool.checkout
    begin
      got = other_conn.select_value("SELECT pg_try_advisory_lock(#{LivestreamBackfill::LOCK_ID})")
      assert_equal true, got

      assert_no_difference "SyncRun.where(status: 'success').count" do
        err = assert_raises(LivestreamBackfill::ValidationError) { svc.apply }
        assert_match "另一個 livestream backfill apply 正在執行中", err.message
      end
      assert_nil Livestream.unscoped.find_by(date: Date.new(2030, 1, 1)).title
    ensure
      other_conn.execute("SELECT pg_advisory_unlock(#{LivestreamBackfill::LOCK_ID})")
      ActiveRecord::Base.connection_pool.checkin(other_conn)
    end

    # 鎖釋放後恢復正常
    result = svc.apply
    assert_equal 1, result[:changed]
  end
end

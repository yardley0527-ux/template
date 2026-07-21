# frozen_string_literal: true

require "test_helper"

# 驗證 db/data/livestream_reconciliation.yml 的實際內容（45 場）與裁定規則。
class LivestreamReconciliationYmlTest < ActiveSupport::TestCase
  CANONICAL_KEYS = %w[
    omnipotent metabolism glutathione collagen turmeric probiotic whitening
    fish_oil cleanse_powder astaxanthin intimate_powder mask vitamin_dk_calcium
  ].freeze

  def entries
    @entries ||= YAML.safe_load_file(
      LivestreamBackfill::YAML_PATH, permitted_classes: [Date], aliases: true
    )
  end

  def find(date_str)
    entries.find { |e| e["date"] == Date.parse(date_str) }
  end

  setup do
    CANONICAL_KEYS.each { |k| CrmProduct.create!(key: k, label: k, status: "confirmed") }
  end

  # ── 測試 2：schema 與 45 場完整性 ────────────────────────────────────────

  test "yaml has exactly 45 events passing full schema validation" do
    assert_equal 45, entries.size
    # load_and_validate_entries! 走完整 schema 驗證（含 product_keys 存在於 crm_products）
    validated = LivestreamBackfill.new(io: StringIO.new).send(:load_and_validate_entries!)
    assert_equal 45, validated.size
  end

  test "every event has at least one valid product key and only canonical keys" do
    entries.each do |e|
      assert e["product_keys"].any?, "#{e['date']} product_keys 為空"
      assert_empty e["product_keys"] - CANONICAL_KEYS, "#{e['date']} 含非法 key"
    end
  end

  test "date corrections carry original_date" do
    corrected = entries.select { |e| e["original_date"] }
    assert_equal [Date.parse("2025-11-21"), Date.parse("2025-12-05")], corrected.map { |e| e["date"] }.sort
    assert_equal Date.parse("2025-11-22"), find("2025-11-21")["original_date"]
    assert_equal Date.parse("2025-12-07"), find("2025-12-05")["original_date"]
  end

  # ── 測試 9、11：衝突 reported 值保持 NULL ───────────────────────────────

  test "conflicting reported values stay null with conflict notes" do
    # 訂單衝突場
    [%w[2025-02-20 reported_orders], %w[2025-08-21 reported_orders], %w[2026-05-22 reported_orders],
     %w[2025-01-05 reported_revenue], %w[2025-02-20 reported_revenue], %w[2025-03-10 reported_revenue],
     %w[2025-10-09 reported_revenue], %w[2025-11-21 reported_revenue], %w[2026-04-10 reported_revenue],
     %w[2026-05-22 reported_revenue]].each do |date_str, field|
      tuple = find(date_str)[field]
      assert_nil tuple["value"], "#{date_str} #{field} 應為 NULL"
      assert tuple["conflict_note"].present?, "#{date_str} #{field} 應有 conflict_note"
    end
  end

  test "p0 events keep both raw values for later verification" do
    %w[2025-10-09 2026-05-22].each do |date_str|
      e = find(date_str)
      assert e["raw"]["all_events"].present? && e["raw"]["live_events"].present?, "#{date_str} raw 必須保留兩套原值"
      assert_match "P0", e["reported_revenue"]["conflict_note"]
    end
  end

  # ── 測試 10：2025-01-13 營收採 live_events ──────────────────────────────

  test "2025-01-13 revenue uses live_events source explicitly" do
    tuple = find("2025-01-13")["reported_revenue"]
    assert_equal 4_465_615, tuple["value"]
    assert_equal "live_events", tuple["source"]
  end

  # ── 測試 12：6/25、7/17 reported 全 NULL ────────────────────────────────

  test "2026-06-25 and 2026-07-17 have null reported values" do
    %w[2026-06-25 2026-07-17].each do |date_str|
      e = find(date_str)
      assert_nil e["reported_orders"]["value"]
      assert_nil e["reported_revenue"]["value"]
      assert_nil e["reported_orders"]["source"]
    end
  end

  # ── 測試 13：付費商品納入、純贈品排除 ───────────────────────────────────

  test "paid add-ons included and pure gifts excluded" do
    # 2026-03-20：「+999 加購（蝦魚D）」是付費加購 → 納入
    keys_0320 = find("2026-03-20")["product_keys"]
    assert_includes keys_0320, "fish_oil"
    assert_includes keys_0320, "astaxanthin"
    assert_includes keys_0320, "vitamin_dk_calcium"

    # 2026-02-06：「益生菌3盒送全能1」的全能是純贈品 → 排除
    keys_0206 = find("2026-02-06")["product_keys"]
    assert_not_includes keys_0206, "omnipotent"
    assert_includes keys_0206, "probiotic"

    # 2025-11-07：「薑黃6瓶送膠原蛋白」的膠原是純贈品 → 排除
    assert_equal ["turmeric"], find("2025-11-07")["product_keys"]
  end

  # ── 測試 14：unmapped_products ──────────────────────────────────────────

  test "unmapped products recorded for the three ruled items only" do
    unmapped = entries.select { |e| e["unmapped_products"].any? }
                      .to_h { |e| [e["date"].iso8601, e["unmapped_products"]] }
    assert_equal(
      { "2024-12-23" => ["酵素"], "2025-01-13" => ["V-Lift美容儀"], "2025-05-09" => ["塑身褲"] },
      unmapped
    )
    # 這三項不得建 crm_product key
    assert_empty CrmProduct.where(label: %w[塑身褲 酵素]).or(CrmProduct.where("label LIKE 'V-Lift%'"))
  end

  # ── 測試 4＋端到端：45 場 preview / apply ───────────────────────────────

  test "end to end: 45-event preview, apply, idempotency and revert" do
    # 依 YAML 造 45 場（有 original_date 的用舊日期，模擬回填前 DB；含 2026-06-25、07-17）
    entries.each do |e|
      Livestream.create!(date: e["original_date"] || e["date"])
    end
    # snapshot 外欄位：revert 不得動到
    Livestream.unscoped.find_by(date: Date.parse("2025-11-22")).update!(notes: "人工備註保留測試")

    # preview：matched=45、missing=0、CSV=46 行、無個資
    csv_path = Rails.root.join("tmp", "reconciliation_full_preview_test.csv")
    preview = LivestreamBackfill.new(io: StringIO.new).preview(csv_path: csv_path)
    assert_equal 45, preview[:rows].size
    assert_equal 0, preview[:missing].size
    assert_equal 46, CSV.read(csv_path).size # header + 45
    assert_no_match(/@/, File.read(csv_path)) # 不含 email 之類個資

    # apply：45 場全部成功、日期修正、title/product_keys 45/45、snapshot 與 SyncRun
    result = LivestreamBackfill.new(io: StringIO.new).apply
    assert_equal 45, result[:changed]
    run = result[:sync_run].reload
    assert_equal "livestream_backfill", run.source
    assert_equal "success", run.status
    assert_not_nil run.finished_at
    assert_equal 45, run.meta["snapshot"].size

    assert Livestream.unscoped.exists?(date: Date.parse("2025-11-21"))
    assert_not Livestream.unscoped.exists?(date: Date.parse("2025-11-22"))
    assert Livestream.unscoped.exists?(date: Date.parse("2025-12-05"))
    assert_not Livestream.unscoped.exists?(date: Date.parse("2025-12-07"))

    assert_equal 45, Livestream.unscoped.where.not(title: nil).count
    assert_equal 45, Livestream.unscoped.where("cardinality(product_keys) > 0").count

    # NULL 規則落到 DB（6/25、7/17 與 P0 場）
    assert_nil Livestream.unscoped.find_by(date: Date.parse("2025-10-09")).reported_revenue
    assert_nil Livestream.unscoped.find_by(date: Date.parse("2026-05-22")).reported_orders
    %w[2026-06-25 2026-07-17].each do |d|
      rec = Livestream.unscoped.find_by(date: Date.parse(d))
      assert_nil rec.reported_orders
      assert_nil rec.reported_revenue
    end
    assert_equal 4_465_615.to_d, Livestream.unscoped.find_by(date: Date.parse("2025-01-13")).reported_revenue

    # 冪等：第二次 no-op、不建新 snapshot
    assert_no_difference "SyncRun.count" do
      second = LivestreamBackfill.new(io: StringIO.new).apply
      assert_equal 0, second[:changed]
      assert_nil second[:sync_run]
    end

    # revert：完整還原第一次 apply 的欄位；snapshot 外欄位不受影響
    LivestreamBackfill.new(io: StringIO.new).revert(confirm: true)
    assert Livestream.unscoped.exists?(date: Date.parse("2025-11-22"))
    assert_not Livestream.unscoped.exists?(date: Date.parse("2025-11-21"))
    assert_equal 0, Livestream.unscoped.where.not(title: nil).count
    assert_equal 0, Livestream.unscoped.where("cardinality(product_keys) > 0").count
    assert_equal 0, Livestream.unscoped.where.not(reported_orders: nil).count
    restored = Livestream.unscoped.find_by(date: Date.parse("2025-11-22"))
    assert_equal "人工備註保留測試", restored.notes # snapshot 外欄位未被 revert 動到
    assert_equal 3, restored.window_days
  end
end

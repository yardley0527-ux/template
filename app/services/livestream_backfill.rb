# frozen_string_literal: true

require "csv"
require "digest"
require "zlib"

# 方案 B PR1：一次性回填 livestreams 的 title / product_keys / reported_* /（兩場）date。
# 唯一資料來源是 db/data/livestream_reconciliation.yml；由 lib/tasks/livestream_backfill.rake 驅動。
#
# - preview：零寫入，產出 45 場 before/after CSV＋摘要
# - apply：整批驗證通過才寫入（單一 transaction）；寫入前把受影響列的 before/after
#   存進 SyncRun（source=livestream_backfill）的 meta.snapshot；冪等（無差異不建 snapshot）
# - revert：只還原 snapshot 記錄的欄位；現值 ≠ snapshot after 時預設跳過（FORCE 才覆蓋）；
#   預設 dry-run，CONFIRM 才寫入
#
# 不呼叫 pg_dump；平台每日備份是額外防線，不在此處理。CSV 與 snapshot 僅含場次欄位，無顧客個資。
class LivestreamBackfill
  YAML_PATH = Rails.root.join("db/data/livestream_reconciliation.yml")
  SYNC_SOURCE = "livestream_backfill"
  EXPECTED_COUNT = 45
  BACKFILL_COLUMNS = %w[date title product_keys reported_orders reported_revenue].freeze
  SOURCES_ENUM = %w[shopline_backend consensus all_events live_events manual].freeze
  CONFIDENCE_ENUM = %w[confirmed probable].freeze
  LOCK_KEY = "livestream_backfill"
  LOCK_ID = Zlib.crc32(LOCK_KEY)

  class ValidationError < StandardError; end

  Row = Struct.new(:entry, :record, :before, :after, keyword_init: true) do
    def changed_columns
      BACKFILL_COLUMNS.select { |col| before[col] != after[col] }
    end

    def changed? = changed_columns.any?
  end

  # expected_count 僅供測試用小型 YAML 覆寫；production rake 一律走預設 45。
  def initialize(yaml_path: YAML_PATH, io: $stdout, expected_count: EXPECTED_COUNT)
    @yaml_path = yaml_path
    @io = io
    @expected_count = expected_count
  end

  # ── preview ──────────────────────────────────────────────────────────────

  def preview(csv_path: default_csv_path)
    entries = load_and_validate_entries!
    rows, missing = build_rows(entries)

    FileUtils.mkdir_p(File.dirname(csv_path))
    File.write(csv_path, rows_to_csv(rows))
    print_summary(entries, rows, missing, csv_path)
    { rows: rows, missing: missing, csv_path: csv_path }
  end

  # ── apply ────────────────────────────────────────────────────────────────

  def apply
    entries = load_and_validate_entries!
    rows, missing = build_rows(entries)

    if missing.any?
      raise ValidationError, "找不到對應場次（依 date/original_date 查無）：#{missing.map { |e| e['date'] }.join(', ')}，abort"
    end

    validate_date_moves!(rows)

    changed = rows.select(&:changed?)
    if changed.empty?
      log "全部 #{rows.size} 場已是目標值，無需變更（不建立 snapshot）。"
      return { changed: 0, sync_run: nil }
    end

    # snapshot 與 45 場更新在同一個 transaction：中途任何失敗 → 整批 rollback，
    # 不留下 success/running 的 SyncRun、也不留下可被 revert 誤用的 snapshot。
    # 失敗軌跡在 rollback 後另建一筆無 snapshot 的 failed SyncRun。
    sync_run = nil
    begin
      ActiveRecord::Base.transaction do
        # PR1 安全補強：transaction-scoped advisory lock，避免兩個 apply 併發寫入
        # 同一批場次。非阻塞（try）＋立即 abort，讓操作者馬上知道有人在跑，
        # 而不是無聲卡住等待。鎖隨 transaction 結束自動釋放。
        acquired = ActiveRecord::Base.connection.select_value(
          "SELECT pg_try_advisory_xact_lock(#{LOCK_ID})"
        )
        raise ValidationError, "另一個 livestream backfill apply 正在執行中，abort" unless acquired

        sync_run = SyncRun.create!(
          source: SYNC_SOURCE, status: "running", started_at: Time.current,
          meta: {
            "yaml_digest" => yaml_digest,
            "snapshot" => changed.map { |r| { "id" => r.record.id, "before" => r.before, "after" => r.after } }
          }
        )
        changed.each { |r| apply_row!(r) }
        sync_run.update!(status: "success", finished_at: Time.current)
      end
    rescue => e
      begin
        SyncRun.create!(source: SYNC_SOURCE, status: "failed",
                        started_at: Time.current, finished_at: Time.current,
                        error_messages: ["#{e.class}: #{e.message}"])
      rescue StandardError
        nil # 失敗記錄寫不進去時以原始例外為準
      end
      raise
    end

    log "已回填 #{changed.size} 場（另 #{rows.size - changed.size} 場已是目標值）。snapshot SyncRun id=#{sync_run.id}"
    { changed: changed.size, sync_run: sync_run }
  end

  # ── revert ───────────────────────────────────────────────────────────────

  def revert(sync_run_id: nil, force: false, confirm: false)
    sync_run = find_snapshot_run!(sync_run_id)
    snapshot = sync_run.meta["snapshot"]
    raise ValidationError, "SyncRun id=#{sync_run.id} 沒有 snapshot，abort" if snapshot.blank?

    plan = snapshot.map { |item| build_revert_plan(item, force: force) }

    unless confirm
      log "[dry-run] 使用 snapshot SyncRun id=#{sync_run.id}（#{sync_run.created_at}）"
      plan.each { |p| log "  #{p[:label]}" }
      log "[dry-run] 未寫入。確認無誤後以 CONFIRM=1 執行。"
      return { dry_run: true, plan: plan }
    end

    ActiveRecord::Base.transaction do
      plan.each do |p|
        next unless p[:action] == :restore

        p[:record].update!(p[:restore_attrs])
      end
    end

    restored = plan.count { |p| p[:action] == :restore }
    skipped  = plan.count { |p| p[:action] == :skip }
    log "revert 完成：還原 #{restored} 場、跳過 #{skipped} 場（snapshot SyncRun id=#{sync_run.id}）"
    { dry_run: false, plan: plan }
  end

  private

  # ── YAML 載入與驗證 ──────────────────────────────────────────────────────

  def load_and_validate_entries!
    raise ValidationError, "找不到 #{@yaml_path}" unless File.exist?(@yaml_path)

    entries = YAML.safe_load_file(@yaml_path, permitted_classes: [Date], aliases: true)
    raise ValidationError, "YAML 根節點必須是陣列" unless entries.is_a?(Array)
    raise ValidationError, "場次數 #{entries.size} ≠ #{@expected_count}，abort" unless entries.size == @expected_count

    dates = entries.map { |e| e["date"] }
    raise ValidationError, "date 有重複或缺漏" if dates.any?(&:nil?) || dates.uniq.size != dates.size

    # PR1 安全補強：original_date 不得重複，也不得與任何其他 entry 的 date 重疊
    # （否則 find_record 依 original_date 查找時可能對到錯誤的場次）。
    originals = entries.filter_map { |e| e["original_date"] }
    raise ValidationError, "original_date 有重複：#{originals.tally.select { |_, n| n > 1 }.keys.join(', ')}" if originals.uniq.size != originals.size

    overlap = originals & dates
    raise ValidationError, "original_date 與其他場次的 date 重疊：#{overlap.join(', ')}" if overlap.any?

    valid_keys = CrmProduct.pluck(:key)
    entries.each { |entry| validate_entry!(entry, valid_keys) }
    entries
  end

  def validate_entry!(entry, valid_keys)
    date = entry["date"]
    raise ValidationError, "#{date}: date 必須是日期" unless date.is_a?(Date)
    raise ValidationError, "#{date}: title 必填" if entry["title"].blank?

    keys = entry["product_keys"]
    raise ValidationError, "#{date}: product_keys 必須是非空陣列" unless keys.is_a?(Array) && keys.any?
    unknown = keys - valid_keys
    raise ValidationError, "#{date}: product_keys 不存在於 crm_products：#{unknown.join(', ')}" if unknown.any?
    raise ValidationError, "#{date}: unmapped_products 必須是陣列" unless entry["unmapped_products"].is_a?(Array)
    raise ValidationError, "#{date}: raw 必須含 all_events/live_events/calendar" unless
      entry["raw"].is_a?(Hash) && (entry["raw"].keys & %w[all_events live_events calendar]).size == 3

    %w[reported_orders reported_revenue].each do |field|
      validate_reported!(entry, field)
    end
  end

  def validate_reported!(entry, field)
    date = entry["date"]
    tuple = entry[field]
    unless tuple.is_a?(Hash) && (%w[value source confidence conflict_note] - tuple.keys).empty?
      raise ValidationError, "#{date}: #{field} 必須含 value/source/confidence/conflict_note"
    end

    value, source, confidence = tuple.values_at("value", "source", "confidence")
    if value.nil?
      raise ValidationError, "#{date}: #{field} value 為 NULL 時 source/confidence 必須為 null" if source || confidence
    else
      raise ValidationError, "#{date}: #{field} source 不合法：#{source.inspect}" unless SOURCES_ENUM.include?(source)
      raise ValidationError, "#{date}: #{field} confidence 不合法：#{confidence.inspect}" unless CONFIDENCE_ENUM.include?(confidence)
    end

    # 規則防線：AE 與 LE 都有值且不一致（AE 的 0 視為缺值）時，
    # 未經人工核對（confidence=confirmed）不得回填任何一邊。
    metric = field == "reported_orders" ? "orders" : "revenue"
    ae = entry.dig("raw", "all_events", metric)
    le = entry.dig("raw", "live_events", metric)
    ae = nil if metric == "revenue" && ae == 0
    conflict = !ae.nil? && !le.nil? && ae != le
    if conflict && !value.nil? && confidence != "confirmed"
      raise ValidationError, "#{date}: #{field} AE/LE 衝突（#{ae} vs #{le}）未經人工核對不得回填"
    end
  end

  # ── row 建構與寫入 ───────────────────────────────────────────────────────

  def build_rows(entries)
    rows = []
    missing = []
    entries.each do |entry|
      record = find_record(entry)
      if record.nil?
        missing << entry
        next
      end
      rows << Row.new(entry: entry, record: record,
                      before: column_values(record),
                      after: target_values(entry))
    end
    [rows, missing]
  end

  # 查找順序：優先以 original_date 找舊資料（未回填），找不到才以 date 判斷是否已回填。
  # original_date 與 date 同時各有一筆 → abort（不得靜默選一）。
  # 同一日期多筆在 DB 層不可能（index_livestreams_on_date unique）。
  def find_record(entry)
    by_original = entry["original_date"] && Livestream.unscoped.find_by(date: entry["original_date"])
    by_date = Livestream.unscoped.find_by(date: entry["date"])
    if by_date && by_original
      raise ValidationError,
            "#{entry['date']} 與 original_date #{entry['original_date']} 同時存在場次，無法判定日期修正對象，abort"
    end

    by_original || by_date
  end

  def column_values(record)
    {
      "date" => record.date.iso8601,
      "title" => record.title,
      "product_keys" => record.product_keys.sort,
      "reported_orders" => record.reported_orders,
      "reported_revenue" => record.reported_revenue&.to_s("F")
    }
  end

  def target_values(entry)
    revenue = entry.dig("reported_revenue", "value")
    {
      "date" => entry["date"].iso8601,
      "title" => entry["title"],
      "product_keys" => entry["product_keys"].sort,
      "reported_orders" => entry.dig("reported_orders", "value"),
      "reported_revenue" => revenue.nil? ? nil : revenue.to_d.to_s("F")
    }
  end

  def validate_date_moves!(rows)
    rows.each do |row|
      next unless row.before["date"] != row.after["date"]

      occupied = Livestream.unscoped.where(date: row.after["date"]).where.not(id: row.record.id).exists?
      raise ValidationError, "日期修正目標 #{row.after['date']} 已存在其他場次，abort" if occupied
    end
  end

  def apply_row!(row)
    attrs = {
      date: row.after["date"],
      title: row.after["title"],
      product_keys: row.entry["product_keys"],
      reported_orders: row.after["reported_orders"],
      reported_revenue: row.after["reported_revenue"]
    }
    row.record.update!(attrs)
  end

  # ── revert 細節 ──────────────────────────────────────────────────────────

  def find_snapshot_run!(sync_run_id)
    scope = SyncRun.where(source: SYNC_SOURCE, status: "success")
    run = sync_run_id ? scope.find_by(id: sync_run_id) : scope.order(created_at: :desc).first
    raise ValidationError, sync_run_id ? "找不到 id=#{sync_run_id} 的成功 #{SYNC_SOURCE} SyncRun" : "沒有任何成功的 #{SYNC_SOURCE} SyncRun 可還原" if run.nil?

    run
  end

  def build_revert_plan(item, force:)
    record = Livestream.unscoped.find_by(id: item["id"])
    return { action: :skip, label: "id=#{item['id']} 已不存在，跳過" } if record.nil?

    current = column_values(record)
    drifted = BACKFILL_COLUMNS.select { |col| current[col] != item["after"][col] }

    if drifted.any? && !force
      return { action: :skip, record: record,
               label: "id=#{record.id}（#{current['date']}）欄位 #{drifted.join('/')} 已被後續修改，跳過（FORCE=1 才覆蓋）" }
    end

    restore_attrs = {
      date: item["before"]["date"],
      title: item["before"]["title"],
      product_keys: item["before"]["product_keys"],
      reported_orders: item["before"]["reported_orders"],
      reported_revenue: item["before"]["reported_revenue"]
    }
    { action: :restore, record: record, restore_attrs: restore_attrs,
      label: "id=#{record.id} 還原 #{item['after']['date']} → #{item['before']['date']}#{drifted.any? ? '（FORCE 覆蓋後續修改）' : ''}" }
  end

  # ── 輸出 ─────────────────────────────────────────────────────────────────

  def rows_to_csv(rows)
    CSV.generate do |csv|
      csv << %w[date_before date_after title_before title_after product_keys_before product_keys_after
                reported_orders_before reported_orders_after reported_revenue_before reported_revenue_after changed_columns]
      rows.sort_by { |r| r.after["date"] }.each do |r|
        csv << [r.before["date"], r.after["date"],
                r.before["title"], r.after["title"],
                r.before["product_keys"].join("|"), r.after["product_keys"].join("|"),
                r.before["reported_orders"], r.after["reported_orders"],
                r.before["reported_revenue"], r.after["reported_revenue"],
                r.changed_columns.join("|")]
      end
    end
  end

  def print_summary(entries, rows, missing, csv_path)
    null_orders  = entries.count { |e| e.dig("reported_orders", "value").nil? }
    null_revenue = entries.count { |e| e.dig("reported_revenue", "value").nil? }
    conflicts    = entries.count do |e|
      %w[reported_orders reported_revenue].any? { |f| e.dig(f, "conflict_note").present? }
    end
    unmapped = entries.select { |e| e["unmapped_products"].any? }

    log "reconciliation：#{entries.size} 場｜date 修正 #{entries.count { |e| e['original_date'] }} 場"
    log "reported_orders NULL：#{null_orders} 場｜reported_revenue NULL：#{null_revenue} 場｜含衝突/缺值註記：#{conflicts} 場"
    log "unmapped_products：#{unmapped.size} 場（#{unmapped.map { |e| "#{e['date']}=#{e['unmapped_products'].join('、')}" }.join('；')}）"
    log "DB 對應：#{rows.size} 場找到｜#{missing.size} 場找不到#{missing.any? ? "（#{missing.map { |e| e['date'] }.join(', ')}）" : ''}"
    log "待變更：#{rows.count(&:changed?)} 場｜已是目標值：#{rows.count { |r| !r.changed? }} 場"
    log "CSV：#{csv_path}"
  end

  def default_csv_path
    Rails.root.join("tmp", "livestream_backfill_preview_#{Time.current.strftime('%Y%m%d%H%M%S')}.csv")
  end

  def yaml_digest
    Digest::SHA256.hexdigest(File.read(@yaml_path))
  end

  def log(msg)
    @io.puts(msg)
  end
end

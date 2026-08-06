# frozen_string_literal: true

# 回購追蹤功能上線前的唯讀健檢（Phase 5）。只查詢、不寫入任何資料——
# 這裡刻意不呼叫 CrmCustomerProductCycleBuilderService.call（那會 upsert
# cycle 資料），只用結構性檢查（table/column/scope 是否存在、能不能查得動）
# 判斷「回購週期 refresh 有沒有能力執行」，不是真的去跑一次。
class CrmRepurchasePreflightCheck
  REQUIRED_TABLES = %w[
    crm_repurchase_cycle_configs
    crm_customer_product_cycles
    crm_customer_product_follow_up_events
    crm_livestream_outreach_tasks
  ].freeze

  REQUIRED_INDEXES = {
    "crm_customer_product_cycles" => %w[idx_cycles_on_identity_product_cycle],
    "crm_livestream_outreach_tasks" => %w[idx_outreach_tasks_on_livestream_cycle idx_outreach_tasks_on_livestream_identity]
  }.freeze

  OUTREACH_CONTROLLERS = %w[
    crm_repurchase_follow_ups livestream_repurchase_candidates crm_livestream_schedules crm_outreach_tasks
  ].freeze

  Result = Struct.new(:label, :value, :level, keyword_init: true) # level: :pass/:warning/:blocker

  def self.call
    new.call
  end

  def call
    results = []
    results << schema_check
    results << product_registry_check
    results << cycle_config_check
    results << unrecognized_product_check
    results << ambiguous_quantity_check
    results << cycle_totals_check
    results << active_task_status_check
    results << livestream_product_keys_check
    results << permission_check
    results << identity_key_check
    results << refresh_capability_check

    {
      results:  results.flatten,
      blockers: results.flatten.select { |r| r.level == :blocker },
      warnings: results.flatten.select { |r| r.level == :warning }
    }
  end

  private

  def schema_check
    missing_tables = REQUIRED_TABLES.reject { |t| ActiveRecord::Base.connection.table_exists?(t) }
    pending = pending_migrations_count

    out = [Result.new(label: "必要資料表", value: missing_tables.empty? ? "4/4 存在" : "缺少：#{missing_tables.join(', ')}",
                       level: missing_tables.empty? ? :pass : :blocker)]

    missing_index_lines = []
    REQUIRED_INDEXES.each do |table, indexes|
      next unless ActiveRecord::Base.connection.table_exists?(table)

      indexes.each do |idx|
        missing_index_lines << "#{table}.#{idx}" unless ActiveRecord::Base.connection.index_name_exists?(table, idx)
      end
    end
    out << Result.new(label: "必要索引", value: missing_index_lines.empty? ? "全部存在" : "缺少：#{missing_index_lines.join(', ')}",
                       level: missing_index_lines.empty? ? :pass : :blocker)

    out << Result.new(label: "待執行 migration", value: "#{pending} 筆",
                       level: pending.zero? ? :pass : :blocker)
    out
  end

  def pending_migrations_count
    ActiveRecord::Base.connection.migration_context.needs_migration? ? ActiveRecord::Base.connection.migration_context.open.pending_migrations.size : 0
  rescue StandardError
    -1 # 無法判斷也不隱瞞，用 -1 標示，外層一律視為 blocker（見呼叫端 pending.zero? 判斷會是 false）
  end

  def product_registry_check
    tracked = CrmProduct.confirmed.where.not(key: CrmRepurchaseCycleConfigSeedService::EXCLUDED_PRODUCT_KEYS).order(:id).pluck(:key, :label)
    ok = tracked.size == 13
    Result.new(label: "13 個追蹤產品總數", value: "#{tracked.size} 個（#{tracked.map(&:last).join('、')}）",
               level: ok ? :pass : :blocker)
  end

  def cycle_config_check
    tracked_keys = CrmProduct.confirmed.where.not(key: CrmRepurchaseCycleConfigSeedService::EXCLUDED_PRODUCT_KEYS).pluck(:key, :label).to_h
    configured_keys = CrmRepurchaseCycleConfig.distinct.pluck(:product_key)
    missing = tracked_keys.keys - configured_keys

    out = [Result.new(label: "有週期設定產品數", value: "#{tracked_keys.size - missing.size} / #{tracked_keys.size}", level: :pass)]
    out << Result.new(
      label: "缺週期設定產品名稱",
      value: missing.empty? ? "無" : missing.map { |k| tracked_keys[k] }.join("、"),
      level: missing.empty? ? :pass : :warning
    )
    out
  end

  def unrecognized_product_check
    report = data_quality_report
    section = report[:unrecognized_product]
    ignored_count = report[:ignored_product][:count]
    Result.new(
      label: "無法辨識產品",
      value: "#{section[:count]} 筆（另有 #{ignored_count} 筆是已知不追蹤商品如面膜，歸類為 ignored、不計入此項）；" \
             "前 20 個原始品名：#{sample_names(section[:sample])}",
      level: section[:count].positive? ? :warning : :pass
    )
  end

  def ambiguous_quantity_check
    report = data_quality_report
    section = report[:ambiguous_quantity]
    Result.new(
      label: "數量含糊",
      value: "#{section[:count]} 筆；前 20 個原始品名：#{sample_names(section[:sample])}",
      level: section[:count].positive? ? :warning : :pass
    )
  end

  def sample_names(sample)
    sample.first(20).map { |r| r[:product_name] }.uniq.join("、").presence || "無"
  end

  def data_quality_report
    @data_quality_report ||= CrmCustomerProductCycleDataQualityReportService.call
  end

  def cycle_totals_check
    [
      Result.new(label: "有效顧客產品週期數（歷史總數）", value: CrmCustomerProductCycle.count, level: :pass),
      Result.new(label: "Active task 數（目前有效任務）", value: CrmCustomerProductCycle.active_follow_up.count, level: :pass)
    ]
  end

  def active_task_status_check
    active = CrmCustomerProductCycle.active_follow_up
    counts = {
      "overdue"        => CrmCustomerProductCycle.with_status_filter(active, "overdue").count,
      "due_today"      => CrmCustomerProductCycle.with_status_filter(active, "due_today").count,
      "due_soon"       => CrmCustomerProductCycle.with_status_filter(active, "due_soon").count,
      "waiting_reply"  => CrmCustomerProductCycle.with_status_filter(active, "waiting_reply").count,
      "rescheduled"    => CrmCustomerProductCycle.with_status_filter(active, "rescheduled").count,
      "paused"         => CrmCustomerProductCycle.with_status_filter(active, "paused").count,
      "repurchased"    => CrmCustomerProductCycle.with_status_filter(active, "repurchased").count
    }
    Result.new(label: "各狀態數量", value: counts.map { |k, v| "#{k}=#{v}" }.join(", "), level: :pass)
  end

  def livestream_product_keys_check
    future = Livestream.where("date >= ?", Date.current)
    with_keys    = future.where("array_length(product_keys, 1) > 0").count
    without_keys = future.where("array_length(product_keys, 1) IS NULL OR array_length(product_keys, 1) = 0").count
    total = with_keys + without_keys

    level = if total.positive? && with_keys.zero?
      :blocker
    elsif without_keys.positive?
      :warning
    else
      :pass
    end

    [
      Result.new(label: "沒有 product_keys 的未來直播", value: without_keys, level: without_keys.positive? ? :warning : :pass),
      Result.new(label: "已設定 product_keys 的未來直播", value: with_keys,
                 level: (total.positive? && with_keys.zero?) ? :blocker : :pass)
    ]
  end

  def permission_check
    admin_role_keys = Role.where(key: "admin").pluck(:id)
    admin_count = User.where(role_id: admin_role_keys).count

    granted_role_ids = PagePermission.where(controller_name: OUTREACH_CONTROLLERS).distinct.pluck(:role_id)
    non_admin_granted_users = User.where(role_id: granted_role_ids).where.not(role_id: admin_role_keys).count

    out = [Result.new(label: "可開啟回購頁面的使用者/角色數",
                       value: "管理者 #{admin_count} 人；另有 PagePermission 授權的一般角色使用者 #{non_admin_granted_users} 人",
                       level: admin_count.positive? ? :pass : :blocker)]

    out << Result.new(
      label: "客服 PagePermission",
      value: non_admin_granted_users.positive? ? "已有 #{non_admin_granted_users} 位非管理者可存取" : "目前只有管理者能存取，客服尚未取得 PagePermission",
      level: non_admin_granted_users.positive? ? :pass : :warning
    )
    out
  end

  # 唯讀 smoke check：確認 identity_key 的組成邏輯（手機優先、否則 email）
  # 對現有資料能算出東西，不是查一個空殼欄位。
  def identity_key_check
    sample = ShoplineOrder.valid_paid
      .joins("LEFT JOIN shopline_customers sc ON LOWER(TRIM(sc.email)) = LOWER(TRIM(shopline_orders.email))")
      .limit(1)
      .pick(Arel.sql("COALESCE(NULLIF(TRIM(sc.mobile_phone), ''), LOWER(TRIM(shopline_orders.email)))"))

    Result.new(label: "identity_key 是否可取得", value: sample.present? ? "可正常取得（範例：#{sample}）" : "查無資料可驗證",
               level: sample.present? ? :pass : :blocker)
  rescue StandardError => e
    Result.new(label: "identity_key 是否可取得", value: "查詢失敗：#{e.class}", level: :blocker)
  end

  # 唯讀結構檢查：builder service 用到的欄位/scope 都能正常解析，不實際呼叫
  # .call（那會寫入 cycle 資料，preflight 禁止寫入）。
  def refresh_capability_check
    CrmCustomerProductCycleBuilderService.respond_to?(:call) or raise "service missing"
    ShoplineOrder.valid_paid.limit(0).to_a
    CrmProduct.confirmed.where.not(key: CrmRepurchaseCycleConfigSeedService::EXCLUDED_PRODUCT_KEYS).limit(0).to_a
    Result.new(label: "回購週期 refresh 是否可執行", value: "結構檢查通過（未實際執行，不寫入資料）", level: :pass)
  rescue StandardError => e
    Result.new(label: "回購週期 refresh 是否可執行", value: "結構檢查失敗：#{e.class} #{e.message}", level: :blocker)
  end
end

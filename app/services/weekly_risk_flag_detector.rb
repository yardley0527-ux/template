# frozen_string_literal: true

# 每週報告「風險提醒」的觸發條件——CLAUDE 明確要求「風險必須設定明確觸發條件，
# 不能全部交由 AI 自由判斷」，所以門檻寫死在這裡當常數，AI 只負責把已經觸發
# 的旗標寫成給老闆看的說明，不能自己發明新的風險判準（WeeklyBriefingService
# 的 prompt 會這樣限制）。
#
# 2026-09-15 大修：原本只有7條規則、且用絕對值判斷逾期人數（見舊版
# PRODUCT_OVERDUE_ABS_THRESHOLD），這裡依照使用者規格擴充成「營收/新客/舊客/
# 會員/資料品質」五大類、每條旗標都帶 severity（high/medium/low/data_anomaly）
# 與 category，讓「分析內文已經指出重大問題但風險區空白」這種矛盾不會再發生。
#
# 每個 flag 是 { key:, category:, severity:, evidence: {} } 的 hash。
class WeeklyRiskFlagDetector
  # ── 門檻常數（全部命名清楚、可個別調整，不藏在條件式裡）───────────
  REVENUE_BELOW_REQUIRED_SEVERE_PCT = 20   # 本週營收低於「達標所需週均」超過此百分比 → high
  REVENUE_COMPARABLE_DROP_PCT       = 30   # 本週營收較可比較基準下降超過此百分比
  CONCENTRATION_TOP_CUSTOMER_PCT    = 10
  CONCENTRATION_TOP_LEVEL_PCT       = 60
  CONCENTRATION_TOP_PRODUCT_PCT     = 50
  CONCENTRATION_TOP_LIVESTREAM_PCT  = 60

  NEW_CUSTOMER_DROP_VS_AVG_PCT      = 30
  NEW_CUSTOMER_MIN_PCT              = 10
  NEW_CUSTOMER_AOV_UP_DROP_PCT      = 20

  RETURNING_CUSTOMER_DROP_VS_AVG_PCT = 20
  RETURNING_AOV_DROP_VS_AVG_PCT      = 20
  COHORT_REPURCHASE_DROP_PCT         = 20   # 相對前一個成熟cohort的回購率下降幅度

  DOWNGRADE_SPIKE_RATIO             = 2.0   # 本週降級人數 / 近4週平均降級人數
  PRODUCT_OVERDUE_GROWTH_PCT        = 15    # 逾期人數週增幅超過此百分比
  PRODUCT_OVERDUE_MIN_INCREASE      = 10    # 且增加的絕對人數至少達到此值
  MID_HIGH_TIER_LOW_ACTIVE_RATE_PCT = 50    # 銀/金/黑卡活躍率低於此百分比（無歷史趨勢資料，暫用絕對值代理）
  BLACK_GOLD_DEPENDENCY_PCT         = 45

  MEMBERSHIP_UNCLASSIFIED_REVENUE_PCT = 10  # 卡別營收加總跟總營收差距超過此百分比 → 視為資料品質異常
  PAYMENT_FAILURE_SPIKE_POINTS        = 3

  SEVERITY_RANK = { "high" => 3, "medium" => 2, "low" => 1, "data_anomaly" => 2 }.freeze
  SEVERITY_LABELS = { "high" => "高", "medium" => "中", "low" => "低", "data_anomaly" => "資料異常" }.freeze
  CATEGORY_LABELS = {
    "revenue" => "營收", "new_customer" => "新客", "old_customer" => "舊客",
    "membership" => "會員", "data_quality" => "資料品質"
  }.freeze
  KEY_LABELS = {
    "revenue_below_required_pace"          => "本週營收低於達標所需週均",
    "revenue_comparable_basis_drop"        => "本週營收較可比較基準大幅下降",
    "consecutive_revenue_decline"          => "營收連續兩週下降",
    "revenue_concentration_customer"       => "營收過度集中單一會員",
    "revenue_concentration_level"          => "營收過度集中單一卡別",
    "revenue_concentration_product"        => "營收過度集中單一商品",
    "revenue_concentration_livestream"     => "營收過度集中單場直播",
    "new_customer_drop_vs_avg4"            => "新客人數低於近4週平均",
    "new_customer_pct_too_low"             => "新客佔比過低",
    "new_customer_two_week_decline"        => "新客人數連續兩週下降",
    "new_customer_aov_up_but_count_down"   => "新客客單價上升但人數下滑",
    "returning_customer_drop_vs_avg4"      => "舊客購買人數低於近4週平均",
    "returning_aov_drop_vs_avg4"           => "舊客客單價低於近4週平均",
    "cohort_repurchase_rate_drop"          => "商品回購率下降",
    "product_overdue_increasing"           => "商品逾期未回購人數增加",
    "downgrade_exceeds_upgrade"            => "降級人數高於升級人數",
    "downgrade_spike_vs_avg4"              => "降級人數異常增加",
    "mid_high_tier_low_active_rate"        => "中高卡活躍率偏低",
    "black_gold_dependency"                => "黑金卡營收依賴度過高",
    "product_repurchase_data_contradiction" => "商品回購資料矛盾",
    "product_cycle_cache_stale"            => "商品回購快取過期",
    "membership_revenue_reconciliation_gap" => "卡別營收加總與總營收不一致",
    "last_year_same_week_data_missing"     => "去年同期資料不完整",
    "livestream_stats_stale"               => "直播統計資料過期",
    "payment_failure_spike"                => "付款失敗/未付款率異常升高"
  }.freeze

  def self.call(metrics)
    new(metrics).call
  end

  def initialize(metrics)
    @m = metrics
  end

  def call
    [
      *revenue_flags, *new_customer_flags, *returning_customer_flags,
      *membership_flags, *data_quality_flags
    ].compact
  end

  private

  def flag(key, category, severity, evidence)
    { key: key, category: category, severity: severity, evidence: evidence }
  end

  # ── 營收風險 ───────────────────────────────────────────────────
  def revenue_flags
    rp = @m["revenue_progress"]
    [
      below_required_pace_flag(rp),
      comparable_drop_flag(rp),
      consecutive_decline_flag(rp),
      *concentration_flags(rp)
    ].compact
  end

  def below_required_pace_flag(rp)
    return nil if rp["already_beat_last_year"]

    required = rp["required_weekly_revenue_to_beat_last_year"].to_f
    return nil if required.zero?

    this_week = rp["this_week_revenue"].to_f
    shortfall_pct = ((required - this_week) / required) * 100
    return nil unless shortfall_pct.positive?

    severity = shortfall_pct >= REVENUE_BELOW_REQUIRED_SEVERE_PCT ? "high" : "medium"
    flag("revenue_below_required_pace", "revenue", severity,
         { this_week_revenue: this_week, required_weekly_revenue: required, shortfall_pct: shortfall_pct.round(1) })
  end

  def comparable_drop_flag(rp)
    comparable = rp["comparable_basis"]
    growth = comparable&.dig("growth_pct")
    return nil if growth.nil? || growth > -REVENUE_COMPARABLE_DROP_PCT

    flag("revenue_comparable_basis_drop", "revenue", "high",
         { growth_pct: growth, basis_label: comparable["basis_label"], sample_size: comparable["sample_size"] })
  end

  def consecutive_decline_flag(rp)
    this_week = rp["this_week_revenue"].to_f
    prev = rp["prev_week_revenue"].to_f
    before_prev = rp["week_before_prev_revenue"].to_f
    return nil unless this_week < prev && prev < before_prev

    flag("consecutive_revenue_decline", "revenue", "high",
         { this_week_revenue: this_week, prev_week_revenue: prev, week_before_prev_revenue: before_prev })
  end

  def concentration_flags(rp)
    c = rp["revenue_concentration"]
    return [] if c.nil?

    [
      threshold_flag(c["top_customer_share_pct"], CONCENTRATION_TOP_CUSTOMER_PCT, "revenue_concentration_customer", { share_pct: c["top_customer_share_pct"] }),
      threshold_flag(c["top_level_share_pct"], CONCENTRATION_TOP_LEVEL_PCT, "revenue_concentration_level", { share_pct: c["top_level_share_pct"], level: c["top_level_name"] }),
      threshold_flag(c["top_product_share_pct"], CONCENTRATION_TOP_PRODUCT_PCT, "revenue_concentration_product", { share_pct: c["top_product_share_pct"], product: c["top_product_name"] }),
      threshold_flag(c["top_livestream_share_pct"], CONCENTRATION_TOP_LIVESTREAM_PCT, "revenue_concentration_livestream", { share_pct: c["top_livestream_share_pct"] })
    ].compact
  end

  def threshold_flag(value, threshold, key, evidence)
    return nil if value.nil? || value < threshold

    flag(key, "revenue", "medium", evidence.merge(threshold_pct: threshold))
  end

  # ── 新客風險 ───────────────────────────────────────────────────
  def new_customer_flags
    nvr = @m["new_vs_returning"]
    this = nvr["this_week"]
    prev = nvr["prev_week"]
    before_prev = nvr["week_before_prev"]
    avg4 = nvr["trailing4_weekly_avg"]

    [
      drop_vs_avg_flag(this["new_customers"], avg4["new_customers"], NEW_CUSTOMER_DROP_VS_AVG_PCT, "new_customer_drop_vs_avg4", "new_customer"),
      new_pct_below_min_flag(this),
      two_week_decline_flag(this["new_customers"], prev["new_customers"], before_prev["new_customers"], "new_customer_two_week_decline", "new_customer"),
      new_aov_up_count_down_flag(this, prev)
    ].compact
  end

  def drop_vs_avg_flag(current, avg, threshold_pct, key, category, severity: "medium")
    return nil if avg.to_f.zero?

    drop_pct = ((avg.to_f - current.to_f) / avg.to_f) * 100
    return nil if drop_pct < threshold_pct

    flag(key, category, severity, { current: current, trailing4_weekly_avg: avg, drop_pct: drop_pct.round(1) })
  end

  def new_pct_below_min_flag(this)
    return nil if this["new_pct"].to_f >= NEW_CUSTOMER_MIN_PCT

    flag("new_customer_pct_too_low", "new_customer", "medium", { new_pct: this["new_pct"], threshold_pct: NEW_CUSTOMER_MIN_PCT })
  end

  def two_week_decline_flag(this_val, prev_val, before_val, key, category)
    return nil unless this_val.to_f < prev_val.to_f && prev_val.to_f < before_val.to_f

    flag(key, category, "medium", { this_week: this_val, prev_week: prev_val, week_before_prev: before_val })
  end

  def new_aov_up_count_down_flag(this, prev)
    return nil unless this["new_aov"].to_f > prev["new_aov"].to_f && prev["new_customers"].to_f.positive?

    drop_pct = ((prev["new_customers"].to_f - this["new_customers"].to_f) / prev["new_customers"].to_f) * 100
    return nil if drop_pct < NEW_CUSTOMER_AOV_UP_DROP_PCT

    flag("new_customer_aov_up_but_count_down", "new_customer", "low",
         { new_aov_this_week: this["new_aov"], new_aov_prev_week: prev["new_aov"], count_drop_pct: drop_pct.round(1) })
  end

  # ── 舊客風險 ───────────────────────────────────────────────────
  def returning_customer_flags
    nvr = @m["new_vs_returning"]
    this = nvr["this_week"]
    avg4 = nvr["trailing4_weekly_avg"]

    [
      drop_vs_avg_flag(this["returning_customers"], avg4["returning_customers"], RETURNING_CUSTOMER_DROP_VS_AVG_PCT, "returning_customer_drop_vs_avg4", "old_customer"),
      drop_vs_avg_flag(this["returning_aov"], avg4["returning_aov"], RETURNING_AOV_DROP_VS_AVG_PCT, "returning_aov_drop_vs_avg4", "old_customer"),
      cohort_repurchase_drop_flag(nvr),
      *product_overdue_flags
    ].compact
  end

  def cohort_repurchase_drop_flag(nvr)
    cohort30 = Array(nvr["cohort_repurchase"]).find { |c| c["window_days"] == 30 }
    return nil unless cohort30 && cohort30["repurchase_rate_pct"] && cohort30["prev_cohort_rate_pct"]
    return nil if cohort30["prev_cohort_rate_pct"].to_f.zero?

    drop_pct = ((cohort30["prev_cohort_rate_pct"].to_f - cohort30["repurchase_rate_pct"].to_f) / cohort30["prev_cohort_rate_pct"].to_f) * 100
    return nil if drop_pct < COHORT_REPURCHASE_DROP_PCT
    return nil unless cohort30["sample_sufficient"]

    flag("cohort_repurchase_rate_drop", "old_customer", "medium",
         { window_days: 30, current_rate_pct: cohort30["repurchase_rate_pct"], prev_rate_pct: cohort30["prev_cohort_rate_pct"], drop_pct: drop_pct.round(1) })
  end

  # 逾期未回購人數天生會隨產品追蹤時間累積成規模很大的常態值，用絕對值判斷
  # 「異常」沒有意義——改用「這週比上週明顯變多」的相對成長幅度＋最小人數
  # 門檻。快取過期（overdue_growth_pct為nil）的產品不列入判斷，避免拿不可信
  # 的數字誤報。
  def product_overdue_flags
    Array(@m.dig("product_repurchase", "products")).filter_map do |p|
      next if p["overdue_growth_pct"].nil?

      increase = p["overdue_count"].to_i - p["overdue_count_prev_week"].to_i
      next unless increase >= PRODUCT_OVERDUE_MIN_INCREASE && p["overdue_growth_pct"].to_f >= PRODUCT_OVERDUE_GROWTH_PCT

      flag("product_overdue_increasing", "old_customer", "medium",
           { product_key: p["product_key"], label: p["label"], overdue_count: p["overdue_count"],
             overdue_count_prev_week: p["overdue_count_prev_week"], overdue_growth_pct: p["overdue_growth_pct"] })
    end
  end

  # ── 會員風險 ───────────────────────────────────────────────────
  def membership_flags
    mem = @m["membership"]
    changes = mem["changes"]

    [
      downgrade_exceeds_upgrade_flag(changes),
      downgrade_spike_flag(changes),
      *low_active_rate_flags(mem),
      black_gold_dependency_flag(mem)
    ].compact
  end

  def downgrade_exceeds_upgrade_flag(changes)
    down = changes["downgrade_count"].to_i
    up = changes["upgrade_count"].to_i
    return nil unless down.positive? && down > up

    severity = (up.zero? || down >= up * DOWNGRADE_SPIKE_RATIO) ? "high" : "medium"
    flag("downgrade_exceeds_upgrade", "membership", severity, { downgrade_count: down, upgrade_count: up })
  end

  def downgrade_spike_flag(changes)
    this_week = changes["downgrade_count"].to_f
    avg4 = changes["trailing4_weekly_avg_downgrade_count"].to_f
    return nil unless avg4.positive? && (this_week / avg4) >= DOWNGRADE_SPIKE_RATIO

    flag("downgrade_spike_vs_avg4", "membership", "medium", { this_week_downgrade_count: this_week, trailing4_weekly_avg: avg4 })
  end

  def low_active_rate_flags(mem)
    Array(mem["levels"]).filter_map do |lv|
      next unless %w[銀卡 金卡 黑卡].include?(lv["level"])
      next if lv["active_rate_pct"].to_f >= MID_HIGH_TIER_LOW_ACTIVE_RATE_PCT

      flag("mid_high_tier_low_active_rate", "membership", "medium",
           { level: lv["level"], active_rate_pct: lv["active_rate_pct"], threshold_pct: MID_HIGH_TIER_LOW_ACTIVE_RATE_PCT,
             note: "CRM 沒有活躍率的歷史週快照，這是絕對值代理指標，不是趨勢下降" })
    end
  end

  def black_gold_dependency_flag(mem)
    share = mem["black_gold_revenue_share_pct"].to_f
    return nil if share < BLACK_GOLD_DEPENDENCY_PCT

    flag("black_gold_dependency", "membership", "medium", { black_gold_revenue_share_pct: share, threshold_pct: BLACK_GOLD_DEPENDENCY_PCT })
  end

  # ── 資料品質風險 ───────────────────────────────────────────────
  def data_quality_flags
    dq = @m["data_quality"]
    oq = @m["order_quality"]

    [
      product_cycle_contradiction_flag(dq),
      stale_cycles_flag(dq),
      membership_reconciliation_flag(dq),
      last_year_incomplete_flag(dq),
      stale_livestream_flag(dq),
      payment_failure_spike_flag(oq)
    ].compact
  end

  def product_cycle_contradiction_flag(dq)
    return nil unless dq["product_cycle_contradiction_detected"]

    flag("product_repurchase_data_contradiction", "data_quality", "data_anomaly",
         { note: "本週舊客購買人數>0，但所有商品回購人數比對結果都是0，數字已被標示為資料不足" })
  end

  def stale_cycles_flag(dq)
    stale = Array(dq["stale_product_cycles"])
    return nil if stale.empty?

    flag("product_cycle_cache_stale", "data_quality", "data_anomaly",
         { product_keys: stale.map { |s| s["product_key"] }, oldest_refreshed_at: stale.map { |s| s["refreshed_at"] }.compact.min })
  end

  def membership_reconciliation_flag(dq)
    pct = dq["membership_unclassified_revenue_pct"].to_f
    return nil if pct < MEMBERSHIP_UNCLASSIFIED_REVENUE_PCT

    flag("membership_revenue_reconciliation_gap", "data_quality", "data_anomaly", { unclassified_revenue_pct: pct })
  end

  def last_year_incomplete_flag(dq)
    return nil unless dq["last_year_same_week_data_incomplete"]

    flag("last_year_same_week_data_missing", "data_quality", "data_anomaly", {})
  end

  def stale_livestream_flag(dq)
    stale = Array(dq["stale_livestream_stats"])
    return nil if stale.empty?

    flag("livestream_stats_stale", "data_quality", "data_anomaly", { events: stale })
  end

  def payment_failure_spike_flag(oq)
    failed_delta = oq["this_week_failed_rate_pct"].to_f - oq["trailing4_failed_rate_pct"].to_f
    unpaid_delta = oq["this_week_unpaid_rate_pct"].to_f - oq["trailing4_unpaid_rate_pct"].to_f
    return nil unless failed_delta >= PAYMENT_FAILURE_SPIKE_POINTS || unpaid_delta >= PAYMENT_FAILURE_SPIKE_POINTS

    flag("payment_failure_spike", "revenue", "medium", oq.slice("this_week_failed_rate_pct", "trailing4_failed_rate_pct", "this_week_unpaid_rate_pct", "trailing4_unpaid_rate_pct"))
  end
end

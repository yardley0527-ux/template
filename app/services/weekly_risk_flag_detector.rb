# frozen_string_literal: true

# 每週報告「風險提醒」的觸發條件——CLAUDE 明確要求「風險必須設定明確觸發條件，
# 不能全部交由 AI 自由判斷」，所以門檻寫死在這裡當常數，AI 只負責把已經觸發
# 的旗標寫成給老闆看的說明，不能自己發明新的風險判準（WeeklyBriefingService
# 的 prompt 會這樣限制）。
#
# 輸入是 WeeklyMetricsService.call 的輸出 hash，純函式、不查資料庫。
class WeeklyRiskFlagDetector
  NEW_PCT_DROP_POINTS          = 5    # 新客佔比比上週或近4週平均低於這個百分點以上
  BLACK_GOLD_DEPENDENCY_PCT    = 45   # 黑金卡營收佔比超過此百分比＝過度依賴少數高卡別
  DOWNGRADE_SPIKE_RATIO        = 2.0  # 本週降級人數 / 近4週平均降級人數
  # 逾期未回購人數本來就會隨產品追蹤時間累積成規模很大的常態值（全能/代謝錠
  # 動輒兩三千人），用絕對值判斷「異常」沒有意義、一定每週都超標——改用「這週
  # 比上週明顯變多」的相對成長幅度＋最小人數門檻（避免小基期產品的雜訊，例如
  # 3人變5人＝+66%但無實質影響）。
  PRODUCT_OVERDUE_GROWTH_PCT   = 15   # 逾期人數週增幅超過此百分比
  PRODUCT_OVERDUE_MIN_INCREASE = 10   # 且增加的絕對人數至少達到此值
  LIVESTREAM_AOV_DROP_PCT      = 15   # 直播客單價相較同類型近3場平均下滑超過此百分比
  REVENUE_PACE_BEHIND          = true # 本週營收負成長 且 所需追趕速度 > 近4週均速 時觸發
  PAYMENT_FAILURE_SPIKE_POINTS = 3    # 付款失敗/未付款佔比比近4週平均高出這個百分點以上

  def self.call(metrics)
    new(metrics).call
  end

  def initialize(metrics)
    @m = metrics
  end

  def call
    [
      new_pct_declining, black_gold_dependency, downgrade_spike,
      *product_overdue_flags, *livestream_aov_flags, revenue_pace_behind, payment_failure_spike
    ].compact
  end

  private

  def new_pct_declining
    nvr = @m["new_vs_returning"]
    this = nvr.dig("this_week", "new_pct").to_f
    prev = nvr.dig("prev_week", "new_pct").to_f
    avg4 = nvr.dig("trailing4_weekly_avg", "new_pct").to_f
    return nil unless (prev - this) >= NEW_PCT_DROP_POINTS && (avg4 - this) >= NEW_PCT_DROP_POINTS

    { key: "new_pct_declining", evidence: { this_week_new_pct: this, prev_week_new_pct: prev, trailing4_avg_new_pct: avg4 } }
  end

  def black_gold_dependency
    share = @m.dig("membership", "black_gold_revenue_share_pct").to_f
    return nil unless share >= BLACK_GOLD_DEPENDENCY_PCT

    { key: "black_gold_dependency", evidence: { black_gold_revenue_share_pct: share, threshold: BLACK_GOLD_DEPENDENCY_PCT } }
  end

  def downgrade_spike
    changes = @m.dig("membership", "changes")
    this_week = changes["downgrade_count"].to_f
    avg4 = changes["trailing4_weekly_avg_downgrade_count"].to_f
    return nil unless avg4.positive? && (this_week / avg4) >= DOWNGRADE_SPIKE_RATIO

    { key: "downgrade_spike", evidence: { this_week_downgrade_count: this_week, trailing4_weekly_avg: avg4 } }
  end

  def product_overdue_flags
    Array(@m.dig("product_repurchase", "products")).filter_map do |p|
      increase = p["overdue_count"].to_i - p["overdue_count_prev_week"].to_i
      next unless increase >= PRODUCT_OVERDUE_MIN_INCREASE && p["overdue_growth_pct"].to_f >= PRODUCT_OVERDUE_GROWTH_PCT

      { key: "product_overdue", evidence: { product_key: p["product_key"], label: p["label"],
                                             overdue_count: p["overdue_count"], overdue_count_prev_week: p["overdue_count_prev_week"],
                                             overdue_growth_pct: p["overdue_growth_pct"] } }
    end
  end

  def livestream_aov_flags
    Array(@m.dig("livestreams", "events")).filter_map do |e|
      delta = e.dig("vs_same_type_avg3", "revenue_delta_pct")
      next if delta.nil? || delta > -LIVESTREAM_AOV_DROP_PCT

      { key: "livestream_revenue_drop", evidence: { date: e["date"], title: e["title"], revenue_delta_pct: delta } }
    end
  end

  def revenue_pace_behind
    rp = @m["revenue_progress"]
    wow = rp["week_over_week_growth_pct"].to_f
    required = rp["required_weekly_revenue_to_beat_last_year"]
    pace = rp["trailing4_weekly_avg_revenue"].to_f
    return nil if required.nil?
    return nil unless wow.negative? && required.to_f > pace

    { key: "revenue_pace_behind", evidence: { week_over_week_growth_pct: wow, required_weekly_revenue: required, trailing4_weekly_avg_revenue: pace } }
  end

  def payment_failure_spike
    oq = @m["order_quality"]
    failed_delta = oq["this_week_failed_rate_pct"].to_f - oq["trailing4_failed_rate_pct"].to_f
    unpaid_delta = oq["this_week_unpaid_rate_pct"].to_f - oq["trailing4_unpaid_rate_pct"].to_f
    return nil unless failed_delta >= PAYMENT_FAILURE_SPIKE_POINTS || unpaid_delta >= PAYMENT_FAILURE_SPIKE_POINTS

    { key: "payment_failure_spike", evidence: oq }
  end
end

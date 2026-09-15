# frozen_string_literal: true

# 每週營運檢討報告的「數據層」——只做確定的計算（人數/營收/比例/成長率/
# 客單價/回購率/升降級數量/年度營收缺口/年底營收預測基礎數據），不做任何
# 判斷或建議。WeeklyBriefingService 把這裡輸出的結構化 hash 交給 Claude API
# 做解讀，AI 不重算任何數字。
#
# 只讀既有分析快取表（livestreams / crm_customer_product_cycles /
# customer_purchase_summaries / membership_level_changes），不重新發明
# 跟 CRM 既有 service 矛盾的邏輯——見各段落註解說明重用了哪一份既有資料。
class WeeklyMetricsService
  ACTIVE_MEMBER_WINDOW_DAYS = 90 # 本報告口徑：trailing 90 天內有有效付款訂單 = 活躍會員（CRM 目前沒有現成的全站「沉睡會員」定義，見下方 build_membership 註解）
  NEW_BUYER_COHORT_WEEKS = 4     # 「新客回購率」觀察窗：近 4 週內首購的新客，回頭看目前是否已有第二筆訂單

  def self.call(week_start: Date.current)
    new(week_start).call
  end

  def initialize(week_start)
    @period = WeeklyPeriod.new(week_start)
  end

  def call
    {
      "period"             => @period.as_json,
      "new_vs_returning"   => build_new_vs_returning,
      "livestreams"        => build_livestreams,
      "membership"         => build_membership,
      "product_repurchase" => build_product_repurchase,
      "revenue_progress"   => build_revenue_progress,
      "order_quality"      => build_order_quality
    }
  end

  private

  # ── 共用：訂單層級（不是商品行層級）金額 ──────────────────────────
  # 同一張訂單常被拆成多個商品行，逐行加總金額會重複計算——用既有的
  # ShoplineOrder::TOTAL_SQL（訂單層級 total_amount，缺值才退回加總
  # checkout_amount）配合 GROUP BY order_number，跟 HighValueOrderScoping
  # 用的是同一份定義。
  def order_level_rows(scope, time_range)
    scope.where(order_date: time_range)
         .group(:order_number)
         .pluck(Arel.sql("MAX(shopline_orders.email)"), Arel.sql("(#{ShoplineOrder::TOTAL_SQL})"))
  end

  def safe_div(num, den)
    return 0.0 if den.to_f.zero?

    (num.to_f / den.to_f)
  end

  def pct(num, den)
    safe_div(num, den) * 100
  end

  def round2(n)
    n.to_f.round(2)
  end

  # ── 1. 新客與舊客分析 ────────────────────────────────────────────
  def customer_segment_stats(scope, time_range)
    rows = order_level_rows(scope, time_range)
    return empty_segment_stats if rows.empty?

    emails = rows.map(&:first).uniq
    first_dates = NewCustomerDefinition.first_purchase_dates(emails)

    new_emails = Set.new
    returning_emails = Set.new
    new_revenue = 0.0
    returning_revenue = 0.0

    rows.each do |email, total|
      if NewCustomerDefinition.new_in_period?(first_dates[email], time_range.begin, time_range.end)
        new_emails << email
        new_revenue += total.to_f
      else
        returning_emails << email
        returning_revenue += total.to_f
      end
    end

    {
      "new_customers"       => new_emails.size,
      "returning_customers" => returning_emails.size,
      "total_customers"     => (new_emails | returning_emails).size,
      "new_revenue"         => round2(new_revenue),
      "returning_revenue"   => round2(returning_revenue),
      "total_revenue"       => round2(new_revenue + returning_revenue),
      "new_aov"             => round2(safe_div(new_revenue, new_emails.size)),
      "returning_aov"       => round2(safe_div(returning_revenue, returning_emails.size)),
      "new_pct"             => round2(pct(new_emails.size, new_emails.size + returning_emails.size)),
      "order_count"         => rows.size
    }
  end

  def empty_segment_stats
    {
      "new_customers" => 0, "returning_customers" => 0, "total_customers" => 0,
      "new_revenue" => 0.0, "returning_revenue" => 0.0, "total_revenue" => 0.0,
      "new_aov" => 0.0, "returning_aov" => 0.0, "new_pct" => 0.0, "order_count" => 0
    }
  end

  def build_new_vs_returning
    base = ShoplineOrder.valid_paid

    this_week = customer_segment_stats(base, @period.time_range)
    prev_week = customer_segment_stats(base, @period.prev_week_time_range)
    last_year_same_week = customer_segment_stats(base, @period.last_year_same_week_range.begin.beginning_of_day..@period.last_year_same_week_range.end.end_of_day)

    # trailing4 是「近 4 週合計」算出來的 distinct 客戶數／訂單數，人數欄位
    # 除以 4 只是「平均每週大約多少」的近似值（同一人跨兩週回購時，合計去重
    # 後的人數會比週次總和少，所以這個近似值會略低於真正的週平均，屬於保守
    # 估計，非精確值）；new_aov／returning_aov／new_pct 是比例，分子分母同時
    # 除以 4 值不變，直接沿用合計期間算出的比例即可，不重複相除。
    trailing4 = customer_segment_stats(base, @period.trailing4_time_range)
    trailing4_weekly_avg = trailing4.merge(
      "new_customers"       => round2(trailing4["new_customers"] / 4.0),
      "returning_customers" => round2(trailing4["returning_customers"] / 4.0),
      "total_customers"     => round2(trailing4["total_customers"] / 4.0),
      "new_revenue"         => round2(trailing4["new_revenue"] / 4.0),
      "returning_revenue"   => round2(trailing4["returning_revenue"] / 4.0),
      "total_revenue"       => round2(trailing4["total_revenue"] / 4.0),
      "order_count"         => round2(trailing4["order_count"] / 4.0)
    )

    {
      "this_week"            => this_week,
      "prev_week"            => prev_week,
      "trailing4_weekly_avg" => trailing4_weekly_avg,
      "last_year_same_week"  => last_year_same_week,
      "new_buyer_repurchase" => new_buyer_repurchase_rate
    }
  end

  # 近 4 週內首購的新客，目前（報告產生當下）是否已經有第二筆訂單
  # （customer_purchase_summaries.purchase_count >= 2）。這是一個提前信號，
  # 不是完整生命週期回購率——cohort 平均只有 0~4 週可以回購，數字天然偏低，
  # AI 產報告時要標明這個限制，不能直接跟長期回購率相提並論。
  def new_buyer_repurchase_rate
    cohort_start = @period.week_end - (NEW_BUYER_COHORT_WEEKS * 7) + 1
    cohort = CustomerPurchaseSummary.where(first_date: cohort_start..@period.week_end)
    total = cohort.count
    repurchased = cohort.where("purchase_count >= 2").count

    {
      "cohort_window_start" => cohort_start,
      "cohort_window_end"   => @period.week_end,
      "cohort_size"         => total,
      "repurchased_count"   => repurchased,
      "repurchase_rate_pct" => round2(pct(repurchased, total))
    }
  end

  # ── 2. 每兩週直播表現 ────────────────────────────────────────────
  # 直接讀 livestreams 表既有的快取欄位（LivestreamStatsRefreshService 維護），
  # 不重新從 shopline_orders 算一次——避免跟 /livestream_overview 等既有頁面
  # 兜不起來。ops:weekly_briefing rake task 會在算這份報告前先呼叫
  # LivestreamStatsRefreshService，確保這裡讀到的是最新快取。
  def build_livestreams
    window_start = @period.week_end - 13
    events = Livestream.where(date: window_start..@period.week_end).order(:date)

    {
      "window_start" => window_start,
      "window_end"   => @period.week_end,
      "events"       => events.map { |ls| livestream_event_payload(ls) }
    }
  end

  def livestream_event_payload(ls)
    aov = safe_div(ls.total_revenue, ls.total_buyers)
    new_pct = pct(ls.new_buyers, ls.total_buyers)
    prev = Livestream.where("date < ?", ls.date).order(date: :desc).first
    primary_product = ls.product_keys.first
    same_type_avg = same_type_average(ls, primary_product)

    {
      "id"                 => ls.id,
      "date"               => ls.date,
      "title"              => ls.title,
      "product_keys"       => ls.product_keys,
      "total_orders"       => ls.total_orders,
      "total_buyers"       => ls.total_buyers,
      "new_buyers"         => ls.new_buyers,
      "returning_buyers"   => ls.total_buyers - ls.new_buyers,
      "new_buyer_pct"      => round2(new_pct),
      "total_revenue"      => ls.total_revenue.to_f,
      "aov"                => round2(aov),
      "revenue_per_order"  => round2(safe_div(ls.total_revenue, ls.total_orders)),
      "membership_split"   => membership_split(ls),
      "stats_refreshed_at" => ls.stats_refreshed_at,
      "stale_stats"        => ls.stats_refreshed_at.nil? || ls.stats_refreshed_at.to_date < ls.date,
      "vs_previous_event"  => prev ? livestream_diff(ls, prev, label: "上一場直播（#{prev.date}）") : nil,
      "vs_same_type_avg3"  => same_type_avg
    }
  end

  def membership_split(ls)
    %w[black gold silver white normal].map do |k|
      count  = ls.public_send("level_#{k}_count")
      amount = ls.public_send("level_#{k}_amount").to_f
      { "level_key" => k, "count" => count, "amount" => amount,
        "revenue_share_pct" => round2(pct(amount, ls.total_revenue)) }
    end
  end

  def livestream_diff(current, other, label:)
    {
      "compared_to"        => label,
      "buyers_delta_pct"   => round2(growth_pct(current.total_buyers, other.total_buyers)),
      "revenue_delta_pct"  => round2(growth_pct(current.total_revenue, other.total_revenue)),
      "aov_delta_pct"      => round2(growth_pct(safe_div(current.total_revenue, current.total_buyers),
                                                 safe_div(other.total_revenue, other.total_buyers))),
      "new_pct_delta"      => round2(pct(current.new_buyers, current.total_buyers) - pct(other.new_buyers, other.total_buyers))
    }
  end

  def same_type_average(ls, primary_product)
    return nil if primary_product.blank?

    peers = Livestream.where("? = ANY(product_keys)", primary_product)
                       .where("date < ?", ls.date)
                       .order(date: :desc)
                       .limit(3)
    return nil if peers.empty?

    {
      "sample_dates"     => peers.map(&:date),
      "avg_buyers"       => round2(peers.sum(&:total_buyers) / peers.size.to_f),
      "avg_revenue"      => round2(peers.sum { |p| p.total_revenue.to_f } / peers.size.to_f),
      "avg_new_pct"      => round2(peers.sum { |p| pct(p.new_buyers, p.total_buyers) } / peers.size.to_f),
      "buyers_delta_pct" => round2(growth_pct(ls.total_buyers, peers.sum(&:total_buyers) / peers.size.to_f)),
      "revenue_delta_pct" => round2(growth_pct(ls.total_revenue, peers.sum { |p| p.total_revenue.to_f } / peers.size.to_f))
    }
  end

  def growth_pct(current, previous)
    return nil if previous.to_f.zero?

    ((current.to_f - previous.to_f) / previous.to_f) * 100
  end

  # ── 3. 會員卡別維護 ──────────────────────────────────────────────
  # 會員數/卡別沿用 MembershipLevels::TARGET_MEMBERSHIPS（跟 MembershipLevelStatsService
  # 同一份卡別清單）；升降級沿用 MembershipLevelChange（既有匯入時偵測寫入的表，
  # 不重新推算）。「即將降級/接近升級門檻」需要 Shopline 官方的會員等級門檻規則，
  # 這份 CRM 資料庫沒有落地這張表（customers_controller.rb 的
  # MEMBERSHIP_MANUAL_REFERENCE 只是使用者手動貼的截圖數字，不是可查詢的門檻設定），
  # 所以這兩項明確標記資料不足，不用猜的門檻公式假裝算得出來。
  def build_membership
    levels = MembershipLevels::TARGET_MEMBERSHIPS
    email_level = ShoplineCustomer.where(membership_level: levels).where.not(email: [nil, ""])
                                   .pluck(:email, :membership_level).to_h
    member_counts = ShoplineCustomer.where(membership_level: levels).group(:membership_level).count

    last_order_by_email = CustomerPurchaseSummary.where(email: email_level.keys)
                                                   .group(:email).maximum(:last_order_date)

    week_rows = order_level_rows(ShoplineOrder.valid_paid, @period.time_range)
    trailing4_rows = order_level_rows(ShoplineOrder.valid_paid, @period.trailing4_time_range)
    ytd_rows = order_level_rows(ShoplineOrder.valid_paid, @period.ytd_time_range)
    last_year_same_rows = order_level_rows(ShoplineOrder.valid_paid, @period.last_year_same_period_time_range)

    active_cutoff = @period.week_end - ACTIVE_MEMBER_WINDOW_DAYS

    level_stats = levels.map do |level|
      level_emails = email_level.select { |_, l| l == level }.keys
      active_count = level_emails.count { |e| last_order_by_email[e].present? && last_order_by_email[e].to_date >= active_cutoff }

      {
        "level"                => level,
        "member_count"         => member_counts[level].to_i,
        "active_count"         => active_count,
        "dormant_count"        => member_counts[level].to_i - active_count,
        "this_week"            => level_revenue_stats(week_rows, email_level, level),
        "trailing4_weekly_avg" => trailing4_weekly_avg_level_stats(trailing4_rows, email_level, level),
        "ytd"                  => level_revenue_stats(ytd_rows, email_level, level),
        "last_year_same_period" => level_revenue_stats(last_year_same_rows, email_level, level)
      }
    end

    total_week_revenue = week_rows.sum { |_, total| total.to_f }
    black_gold_revenue = week_rows.sum { |email, total| %w[黑卡 金卡].include?(email_level[email]) ? total.to_f : 0.0 }

    {
      "active_window_days"           => ACTIVE_MEMBER_WINDOW_DAYS,
      "levels"                       => level_stats,
      "changes"                      => membership_changes,
      "black_gold_revenue_share_pct" => round2(pct(black_gold_revenue, total_week_revenue)),
      "near_threshold_data_available" => false,
      "near_threshold_note"           => "Shopline 會員等級升降門檻規則未落地在本站資料庫（僅有使用者手動提供的歷史截圖，非可查詢資料），無法計算「即將降級／接近升級門檻」人數，資料不足，需人工確認。"
    }
  end

  def level_revenue_stats(rows, email_level, level)
    filtered = rows.select { |email, _| email_level[email] == level }
    revenue = filtered.sum { |_, total| total.to_f }
    buyers = filtered.map(&:first).uniq.size
    {
      "revenue"       => round2(revenue),
      "buyers"        => buyers,
      "order_count"   => filtered.size,
      "aov"           => round2(safe_div(revenue, buyers)),
      "orders_per_buyer" => round2(safe_div(filtered.size, buyers))
    }
  end

  # 近4週週平均：revenue/buyers/order_count 是「量」，除以4取近似週平均合理；
  # aov／orders_per_buyer 是比例（revenue/buyers、order_count/buyers），本身
  # 不能再除以4（那樣會把數字砍成1/4，是明顯錯誤）——直接沿用4週合計期間
  # 算出的比例即可。
  def trailing4_weekly_avg_level_stats(rows, email_level, level)
    raw = level_revenue_stats(rows, email_level, level)
    {
      "revenue"          => round2(raw["revenue"] / 4.0),
      "buyers"           => round2(raw["buyers"] / 4.0),
      "order_count"      => round2(raw["order_count"] / 4.0),
      "aov"              => raw["aov"],
      "orders_per_buyer" => raw["orders_per_buyer"]
    }
  end

  def membership_changes
    week_changes = MembershipLevelChange.where(changed_at: @period.time_range)
    upgrade_emails = week_changes.upgrades.pluck(:email).compact.uniq
    downgrade_emails = week_changes.downgrades.pluck(:email).compact.uniq

    {
      "upgrade_count"   => week_changes.upgrades.count,
      "downgrade_count" => week_changes.downgrades.count,
      "by_to_level"     => week_changes.upgrades.group(:to_level).count,
      "by_from_level"   => week_changes.downgrades.group(:from_level).count,
      "upgrade_revenue_this_week"   => round2(revenue_for_emails(upgrade_emails)),
      "downgrade_revenue_this_week" => round2(revenue_for_emails(downgrade_emails)),
      "trailing4_weekly_avg_downgrade_count" => round2(MembershipLevelChange.where(changed_at: @period.trailing4_time_range).downgrades.count / 4.0),
      "trailing4_weekly_avg_upgrade_count"   => round2(MembershipLevelChange.where(changed_at: @period.trailing4_time_range).upgrades.count / 4.0),
      "revenue_note" => "升降級金額＝該群客戶本週下單總額（近似值，不是導致升降等的單一訂單金額，membership_level_changes 沒有記錄金額欄位）"
    }
  end

  # ── 訂單品質（退款/取消異常偵測用）──────────────────────────────
  # shopline_orders.payment_status 只有三種值（已付款/付款失敗/未付款，
  # order_status 全表皆為 NULL，見 ShoplineOrder.valid_paid 註解），沒有
  # 獨立的退款欄位——用「付款失敗／未付款佔比」作為異常代理指標。
  def build_order_quality
    this_week_all = ShoplineOrder.where(order_date: @period.time_range)
    trailing4_all = ShoplineOrder.where(order_date: @period.trailing4_time_range)
    this_week_total = this_week_all.count
    trailing4_total = trailing4_all.count

    {
      "this_week_failed_rate_pct"  => round2(pct(this_week_all.where(payment_status: "付款失敗").count, this_week_total)),
      "trailing4_failed_rate_pct"  => round2(pct(trailing4_all.where(payment_status: "付款失敗").count, trailing4_total)),
      "this_week_unpaid_rate_pct"  => round2(pct(this_week_all.where(payment_status: "未付款").count, this_week_total)),
      "trailing4_unpaid_rate_pct"  => round2(pct(trailing4_all.where(payment_status: "未付款").count, trailing4_total))
    }
  end

  def revenue_for_emails(emails)
    return 0.0 if emails.empty?

    order_level_rows(ShoplineOrder.valid_paid.where(email: emails), @period.time_range).sum { |_, total| total.to_f }
  end

  # ── 4. 商品回購與沉睡狀況 ────────────────────────────────────────
  # 逾期/即將到期沿用 CrmCustomerProductCycle（回購追蹤 Dashboard 同一份資料
  # 與狀態定義，見 CrmRepurchaseDashboardQuery），回購週期中位數沿用
  # CrmRepurchaseCycleConfig；不另訂一份平行的瓶數/天數計算。
  EXCLUDED_PRODUCT_KEYS = defined?(CrmRepurchaseCycleConfigSeedService) ? CrmRepurchaseCycleConfigSeedService::EXCLUDED_PRODUCT_KEYS : [].freeze

  def build_product_repurchase
    products = CrmProduct.confirmed.where.not(key: EXCLUDED_PRODUCT_KEYS).order(:id)

    {
      "products" => products.map { |crm| product_payload(crm) }
    }
  end

  def product_payload(crm)
    scope = ShoplineOrder.valid_paid.where(crm.matching_sql_pattern)
    week_stats = customer_segment_stats(scope, @period.time_range)

    cycles = CrmCustomerProductCycle.active_as_of(@period.week_end).for_product(crm.key)
    overdue   = CrmCustomerProductCycle.with_status_filter(cycles, "overdue", reference_date: @period.week_end).count
    due_today = CrmCustomerProductCycle.with_status_filter(cycles, "due_today", reference_date: @period.week_end).count
    due_soon  = CrmCustomerProductCycle.with_status_filter(cycles, "due_soon", reference_date: @period.week_end).count
    tracking_total = cycles.count

    # 逾期人數天生會隨產品追蹤時間累積成一個規模很大的常態庫存（例如全能/代謝錠
    # 動輒兩三千人逾期未回購)，用絕對值判斷「異常」沒有意義——一定每週都超標。
    # 風險偵測要看的是「這週逾期人數相較上週是不是明顯變多」，所以額外算上週同
    # 一天基準的逾期人數，供 WeeklyRiskFlagDetector 用成長幅度判斷，不是用絕對值。
    prev_cycles = CrmCustomerProductCycle.active_as_of(@period.prev_week_end).for_product(crm.key)
    overdue_prev_week = CrmCustomerProductCycle.with_status_filter(prev_cycles, "overdue", reference_date: @period.prev_week_end).count

    repurchased_this_week = CrmCustomerProductCycle.for_product(crm.key)
                                                     .where(next_same_product_order_date: @period.range)
                                                     .count

    all_cycles_for_product = CrmCustomerProductCycle.for_product(crm.key)
    lifetime_total = all_cycles_for_product.count
    lifetime_matched = all_cycles_for_product.matched.count

    configs = CrmRepurchaseCycleConfig.where(product_key: crm.key)
    weighted_days = configs.sum { |c| c.median_days.to_f * [c.sample_size, 1].max }
    weighted_weight = configs.sum { |c| [c.sample_size, 1].max }

    {
      "product_key"              => crm.key,
      "label"                    => crm.label,
      "availability_status"      => crm.availability_status,
      "this_week"                => week_stats,
      "repurchased_this_week"    => repurchased_this_week,
      "overdue_count"            => overdue,
      "overdue_count_prev_week"  => overdue_prev_week,
      "overdue_growth_pct"       => round2(growth_pct(overdue, overdue_prev_week) || 0),
      "due_today_count"          => due_today,
      "due_soon_count"           => due_soon,
      "tracking_total"           => tracking_total,
      "lifetime_repurchase_rate_pct" => round2(pct(lifetime_matched, lifetime_total)),
      "median_repurchase_days"   => configs.any? ? round2(weighted_days / weighted_weight) : nil
    }
  end

  # ── 5. 營收進度 ──────────────────────────────────────────────────
  def build_revenue_progress
    base = ShoplineOrder.valid_paid

    this_week = order_level_rows(base, @period.time_range).sum { |_, t| t.to_f }
    prev_week = order_level_rows(base, @period.prev_week_time_range).sum { |_, t| t.to_f }
    mtd = order_level_rows(base, @period.week_end.beginning_of_month.beginning_of_day..@period.week_end.end_of_day).sum { |_, t| t.to_f }
    ytd = order_level_rows(base, @period.ytd_time_range).sum { |_, t| t.to_f }
    last_year_same_ytd = order_level_rows(base, @period.last_year_same_period_time_range).sum { |_, t| t.to_f }
    last_year_full = order_level_rows(base, @period.last_year_time_range).sum { |_, t| t.to_f }
    trailing4_total = order_level_rows(base, @period.trailing4_time_range).sum { |_, t| t.to_f }
    trailing4_weekly_avg = trailing4_total / 4.0

    weeks_remaining = @period.weeks_remaining_in_year
    gap = last_year_full - ytd
    required_weekly_revenue = weeks_remaining.positive? ? gap / weeks_remaining : nil

    projected_base = ytd + (trailing4_weekly_avg * weeks_remaining)
    projected_optimistic = ytd + (trailing4_weekly_avg * 1.15 * weeks_remaining)
    projected_conservative = ytd + (trailing4_weekly_avg * 0.85 * weeks_remaining)

    {
      "this_week_revenue"          => round2(this_week),
      "prev_week_revenue"          => round2(prev_week),
      "week_over_week_growth_pct"  => round2(growth_pct(this_week, prev_week) || 0),
      "mtd_revenue"                => round2(mtd),
      "ytd_revenue"                => round2(ytd),
      "last_year_same_period_ytd_revenue" => round2(last_year_same_ytd),
      "last_year_full_year_revenue"       => round2(last_year_full),
      "yoy_growth_pct"             => round2(growth_pct(ytd, last_year_same_ytd) || 0),
      "gap_to_beat_last_year"      => round2(gap),
      "already_beat_last_year"     => gap <= 0,
      "days_remaining_in_year"     => @period.days_remaining_in_year,
      "weeks_remaining_in_year"    => round2(weeks_remaining),
      "required_weekly_revenue_to_beat_last_year" => required_weekly_revenue && round2(required_weekly_revenue),
      "trailing4_weekly_avg_revenue" => round2(trailing4_weekly_avg),
      "projected_year_end" => {
        "conservative" => round2(projected_conservative),
        "base"         => round2(projected_base),
        "optimistic"   => round2(projected_optimistic)
      },
      "will_beat_last_year_base_case" => projected_base >= last_year_full
    }
  end
end

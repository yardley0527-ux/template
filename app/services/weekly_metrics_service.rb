# frozen_string_literal: true

# 每週經營決策報告的「數據層」——只做確定的計算（人數/營收/比例/成長率/
# 客單價/回購率/升降級數量/年度營收缺口/年底營收預測基礎數據），不做任何
# 判斷或建議。WeeklyBriefingService 把這裡輸出的結構化 hash 交給 Claude API
# 做解讀，AI 不重算任何數字。
#
# 只讀既有分析快取表（livestreams / crm_customer_product_cycles /
# customer_purchase_summaries / membership_level_changes），不重新發明
# 跟 CRM 既有 service 矛盾的邏輯——見各段落註解說明重用了哪一份既有資料。
#
# 2026-09-15 大修（見 weekly-briefing-fix 系列）：修正「商品回購全部為0」——
# 根因是 crm_customer_product_cycles 沒有在產生報告前重新整理（見
# WeeklyBriefingRunner），這裡新增「快取過期」與「矛盾偵測」兩層防呆，
# 資料不可信時回傳 nil 讓畫面顯示「資料不足」而不是誤導性的 0。同時新增
# 週型分類（直播週/活動週/自然週）、可比較基準營收成長、cohort 回購率、
# 逾期名單分級距與可行動人數、會員卡別拆解與加總校驗、多期營收預測情境。
class WeeklyMetricsService
  ACTIVE_MEMBER_WINDOW_DAYS = 90   # 本報告口徑：trailing 90 天內有有效付款訂單 = 活躍會員（CRM 沒有現成的全站「沉睡會員」定義）
  CYCLE_STALE_HOURS         = 72   # crm_customer_product_cycles 距離上次 refreshed_at 超過此時數，視為過期、不可信任回購/逾期成長數字
  GROWTH_TARGET_PCT         = 10.0 # 年度成長目標（相對去年全年營收）——CRM 沒有正式的年度目標設定來源，此為預設參數，非硬編金額，可依實際目標調整
  SAFETY_BUFFER_PCT         = 10.0 # 經營安全線 = 最低警戒線 × (1 + 此緩衝)
  COHORT_WINDOWS            = [7, 14, 30, 60, 90].freeze # 新客回購率觀察窗（天），只有已完整走完窗口的 cohort 才計入分母

  def self.call(week_start: Date.current)
    new(week_start).call
  end

  def initialize(week_start)
    @period = WeeklyPeriod.new(week_start)
  end

  def call
    new_vs_returning   = build_new_vs_returning
    week_type          = WeeklyWeekTypeClassifier.call(@period)
    product_repurchase = build_product_repurchase(new_vs_returning)
    membership         = build_membership
    revenue_progress   = build_revenue_progress(week_type)
    order_quality      = build_order_quality
    data_quality       = build_data_quality(product_repurchase, membership)

    {
      "period"             => @period.as_json,
      "week_type"          => week_type,
      "new_vs_returning"   => new_vs_returning,
      "livestreams"        => build_livestreams,
      "membership"         => membership,
      "product_repurchase" => product_repurchase,
      "revenue_progress"   => revenue_progress,
      "order_quality"      => order_quality,
      "data_quality"       => data_quality,
      "data_gaps"          => build_data_gaps(week_type, revenue_progress, membership, data_quality)
    }
  end

  private

  # ── 共用：訂單層級（不是商品行層級）金額 ──────────────────────────
  def order_level_rows(scope, time_range)
    scope.where(order_date: time_range)
         .group(:order_number)
         .pluck(Arel.sql("MAX(shopline_orders.email)"), Arel.sql("(#{ShoplineOrder::TOTAL_SQL})"))
  end

  def weekly_total(scope, time_range)
    order_level_rows(scope, time_range).sum { |_, t| t.to_f }
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

  def growth_pct(current, previous)
    return nil if previous.to_f.zero?

    ((current.to_f - previous.to_f) / previous.to_f) * 100
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
    week_before_prev = customer_segment_stats(base, WeeklyPeriod.for_week_start(@period.week_start - 14).time_range)
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
      "week_before_prev"     => week_before_prev,
      "trailing4_weekly_avg" => trailing4_weekly_avg,
      "last_year_same_week"  => last_year_same_week,
      "cohort_repurchase"    => cohort_repurchase_rates
    }
  end

  # 新客回購率改用「成熟 cohort」：只看首購週已經完整走完對應天數觀察窗的
  # 那一週新客，未滿窗口的顧客不會被算進分母（例如算30天回購率時，首購未滿
  # 30天的人整批排除，不是全部新客都塞進同一個分母）。
  def cohort_repurchase_rates
    COHORT_WINDOWS.map do |days|
      cohort_end = @period.week_end - days
      cohort_start = cohort_end - 6
      cohort = CustomerPurchaseSummary.where(first_date: cohort_start..cohort_end)
      total = cohort.count
      repurchased = cohort.where("purchase_count >= 2").count

      prev_end = cohort_end - 7
      prev_start = prev_end - 6
      prev_cohort = CustomerPurchaseSummary.where(first_date: prev_start..prev_end)
      prev_total = prev_cohort.count
      prev_repurchased = prev_cohort.where("purchase_count >= 2").count

      historical_rates = (2..8).filter_map do |n|
        he = cohort_end - (7 * n)
        hs = he - 6
        h = CustomerPurchaseSummary.where(first_date: hs..he)
        ht = h.count
        next nil if ht < 10

        pct(h.where("purchase_count >= 2").count, ht)
      end

      {
        "window_days"            => days,
        "cohort_start"           => cohort_start,
        "cohort_end"             => cohort_end,
        "sample_size"            => total,
        "repurchased_count"      => repurchased,
        "repurchase_rate_pct"    => total.positive? ? round2(pct(repurchased, total)) : nil,
        "sample_sufficient"      => total >= 30,
        "prev_cohort_rate_pct"   => prev_total.positive? ? round2(pct(prev_repurchased, prev_total)) : nil,
        "historical_avg_rate_pct" => historical_rates.any? ? round2(historical_rates.sum / historical_rates.size) : nil,
        "historical_sample_weeks" => historical_rates.size
      }
    end
  end

  # ── 2. 每兩週直播表現 ────────────────────────────────────────────
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

  # ── 3. 會員卡別維護 ──────────────────────────────────────────────
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
      total_members = member_counts[level].to_i

      {
        "level"                 => level,
        "member_count"          => total_members,
        "active_count"          => active_count,
        "dormant_count"         => total_members - active_count,
        "active_rate_pct"       => round2(pct(active_count, total_members)),
        "this_week"             => level_revenue_stats(week_rows, email_level, level),
        "trailing4_weekly_avg"  => trailing4_weekly_avg_level_stats(trailing4_rows, email_level, level),
        "ytd"                   => level_revenue_stats(ytd_rows, email_level, level),
        "last_year_same_period" => level_revenue_stats(last_year_same_rows, email_level, level),
        "ytd_concentration"     => concentration_stats(ytd_rows, email_level, level)
      }
    end

    total_week_revenue = week_rows.sum { |_, total| total.to_f }
    black_gold_revenue = week_rows.sum { |email, total| %w[黑卡 金卡].include?(email_level[email]) ? total.to_f : 0.0 }
    classified_revenue = week_rows.sum { |email, total| email_level.key?(email) ? total.to_f : 0.0 }
    unclassified_revenue = total_week_revenue - classified_revenue

    {
      "active_window_days"           => ACTIVE_MEMBER_WINDOW_DAYS,
      "levels"                       => level_stats,
      "changes"                      => membership_changes,
      "black_gold_revenue_share_pct" => round2(pct(black_gold_revenue, total_week_revenue)),
      "reconciliation" => {
        "total_week_revenue"    => round2(total_week_revenue),
        "classified_revenue"    => round2(classified_revenue),
        "unclassified_revenue"  => round2(unclassified_revenue),
        "unclassified_pct"      => round2(pct(unclassified_revenue, total_week_revenue)),
        "note" => "unclassified＝訂單 email 在 shopline_customers 找不到卡別（例如訪客結帳、資料未同步）"
      },
      "near_threshold_data_available" => false
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
  # aov／orders_per_buyer 是比例，本身不能再除以4——直接沿用4週合計期間算出
  # 的比例即可。
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

  # 該卡別 YTD 營收集中度：前10名會員／前20%會員的營收佔比，用來判斷卡別
  # 成長是「人數/活躍率/頻次/客單價普遍提升」還是「少數大額會員撐起來」。
  def concentration_stats(rows, email_level, level)
    revenue_by_email = Hash.new(0.0)
    rows.each { |email, total| revenue_by_email[email] += total.to_f if email_level[email] == level }
    return { "member_count_with_orders" => 0, "top10_revenue_share_pct" => nil, "top20pct_revenue_share_pct" => nil } if revenue_by_email.empty?

    sorted = revenue_by_email.values.sort.reverse
    total = sorted.sum
    top10 = sorted.first(10).sum
    top20pct_n = [(sorted.size * 0.2).ceil, 1].max
    top20pct = sorted.first(top20pct_n).sum

    {
      "member_count_with_orders"   => sorted.size,
      "top10_revenue_share_pct"    => round2(pct(top10, total)),
      "top20pct_revenue_share_pct" => round2(pct(top20pct, total)),
      "top20pct_member_count"      => top20pct_n
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

  def revenue_for_emails(emails)
    return 0.0 if emails.empty?

    order_level_rows(ShoplineOrder.valid_paid.where(email: emails), @period.time_range).sum { |_, total| total.to_f }
  end

  # ── 4. 商品回購與沉睡狀況 ────────────────────────────────────────
  EXCLUDED_PRODUCT_KEYS = defined?(CrmRepurchaseCycleConfigSeedService) ? CrmRepurchaseCycleConfigSeedService::EXCLUDED_PRODUCT_KEYS : [].freeze

  # 2026-09-15 修正：先各自算出每個產品的 payload，再做「本週舊客購買人數>0
  # 但所有產品回購人數都是0」的矛盾偵測——這是根因分析挖出的真實 bug（
  # crm_customer_product_cycles 一個月沒有重新整理，見 WeeklyBriefingRunner），
  # 這裡加防呆讓同一類問題以後不會再無聲產出誤導性的0，而是清楚標示資料不足。
  def build_product_repurchase(new_vs_returning)
    products = CrmProduct.confirmed.where.not(key: EXCLUDED_PRODUCT_KEYS).order(:id)
    payloads = products.map { |crm| product_payload(crm) }

    returning_customers_this_week = new_vs_returning.dig("this_week", "returning_customers").to_i
    all_repurchased_zero = payloads.any? && payloads.all? { |p| p["repurchased_this_week"] == 0 }
    contradiction = returning_customers_this_week.positive? && all_repurchased_zero

    if contradiction
      payloads.each do |p|
        p["repurchased_this_week"] = nil
        p["repurchased_this_week_note"] =
          "資料不足／計算未完成：本週有 #{returning_customers_this_week} 位舊客購買，但本產品比對到的回購人數為0，" \
          "研判 crm_customer_product_cycles 快取過期或比對失敗，此數字不可信任。"
      end
    end

    {
      "products"                      => payloads,
      "contradiction_detected"        => contradiction,
      "returning_customers_this_week" => returning_customers_this_week
    }
  end

  def product_payload(crm)
    scope = ShoplineOrder.valid_paid.where(crm.matching_sql_pattern)
    week_stats = customer_segment_stats(scope, @period.time_range)

    cycles_refreshed_at = CrmCustomerProductCycle.for_product(crm.key).maximum(:refreshed_at)
    stale = cycles_refreshed_at.nil? || cycles_refreshed_at < CYCLE_STALE_HOURS.hours.ago

    cycles = CrmCustomerProductCycle.active_as_of(@period.week_end).for_product(crm.key)
    overdue   = CrmCustomerProductCycle.with_status_filter(cycles, "overdue", reference_date: @period.week_end).count
    due_today = CrmCustomerProductCycle.with_status_filter(cycles, "due_today", reference_date: @period.week_end).count
    due_soon  = CrmCustomerProductCycle.with_status_filter(cycles, "due_soon", reference_date: @period.week_end).count
    tracking_total = cycles.count

    prev_cycles = CrmCustomerProductCycle.active_as_of(@period.prev_week_end).for_product(crm.key)
    overdue_prev_week = CrmCustomerProductCycle.with_status_filter(prev_cycles, "overdue", reference_date: @period.prev_week_end).count

    # 快取過期時，「本週回購人數」與「逾期成長幅度」都建立在同一份沒有反映
    # 最新訂單的靜態快照上，不能顯示成「這週的真實變化」——回傳 nil，畫面顯示
    # 「資料不足／計算未完成」，不可以顯示誤導性的 0。
    repurchased_this_week = stale ? nil : CrmCustomerProductCycle.for_product(crm.key).where(next_same_product_order_date: @period.range).count
    overdue_growth_pct = stale ? nil : round2(growth_pct(overdue, overdue_prev_week) || 0)

    all_cycles_for_product = CrmCustomerProductCycle.for_product(crm.key)
    lifetime_total = all_cycles_for_product.count
    lifetime_matched = all_cycles_for_product.matched.count

    configs = CrmRepurchaseCycleConfig.where(product_key: crm.key)
    weighted_days = configs.sum { |c| c.median_days.to_f * [c.sample_size, 1].max }
    weighted_weight = configs.sum { |c| [c.sample_size, 1].max }

    actionability = ProductRepurchaseActionabilityService.call(
      product_key: crm.key, reference_date: @period.week_end, availability_status: crm.availability_status
    )

    {
      "product_key"              => crm.key,
      "label"                    => crm.label,
      "availability_status"      => crm.availability_status,
      "this_week"                => week_stats,
      "cycles_refreshed_at"      => cycles_refreshed_at,
      "cycles_stale"             => stale,
      "repurchased_this_week"    => repurchased_this_week,
      "overdue_count"            => overdue,
      "overdue_count_prev_week"  => overdue_prev_week,
      "overdue_growth_pct"       => overdue_growth_pct,
      "due_today_count"          => due_today,
      "due_soon_count"           => due_soon,
      "tracking_total"           => tracking_total,
      "lifetime_repurchase_rate_pct" => round2(pct(lifetime_matched, lifetime_total)),
      "median_repurchase_days"   => configs.any? ? round2(weighted_days / weighted_weight) : nil,
      "actionability"            => actionability
    }
  end

  # ── 訂單品質（退款/取消異常偵測用）──────────────────────────────
  def build_order_quality
    this_week_all = ShoplineOrder.where(order_date: @period.time_range)
    trailing4_all = ShoplineOrder.where(order_date: @period.trailing4_time_range)
    this_week_total = this_week_all.count
    trailing4_total = trailing4_all.count

    {
      "this_week_failed_rate_pct"  => round2(pct(this_week_all.where(payment_status: "付款失敗").count, this_week_total)),
      "trailing4_failed_rate_pct"  => round2(pct(trailing4_all.where(payment_status: "付款失敗").count, trailing4_total)),
      "this_week_unpaid_rate_pct"  => round2(pct(this_week_all.where(payment_status: "未付款").count, this_week_total)),
      "trailing4_unpaid_rate_pct"  => round2(pct(trailing4_all.where(payment_status: "未付款").count, trailing4_total)),
      "funnel_data_available"      => false
    }
  end

  # ── 5. 營收進度與年度預測 ──────────────────────────────────────────
  def build_revenue_progress(week_type)
    base = ShoplineOrder.valid_paid

    this_week = weekly_total(base, @period.time_range)
    prev_week = weekly_total(base, @period.prev_week_time_range)
    week_before_prev = weekly_total(base, WeeklyPeriod.for_week_start(@period.week_start - 14).time_range)
    mtd = weekly_total(base, @period.week_end.beginning_of_month.beginning_of_day..@period.week_end.end_of_day)
    ytd = weekly_total(base, @period.ytd_time_range)
    last_year_same_ytd = weekly_total(base, @period.last_year_same_period_time_range)
    last_year_full = weekly_total(base, @period.last_year_time_range)

    trailing4_avg  = trailing_weekly_avg(base, 4)
    trailing8_avg  = trailing_weekly_avg(base, 8)
    trailing13_series = weekly_totals_series(base, 13)
    trailing13_avg = trailing13_series.sum / [trailing13_series.size, 1].max.to_f
    trimmed13_avg  = trimmed_average(trailing13_series)

    week_type_avgs = historical_week_type_averages(base)
    comparable = comparable_basis_stats(week_type, base)
    concentration = revenue_concentration(base)

    weeks_remaining = @period.weeks_remaining_in_year
    gap = last_year_full - ytd
    required_weekly = weeks_remaining.positive? ? gap / weeks_remaining : nil
    safety_line = required_weekly ? required_weekly * (1 + (SAFETY_BUFFER_PCT / 100.0)) : nil
    growth_target_total = last_year_full * (1 + (GROWTH_TARGET_PCT / 100.0))
    growth_target_weekly = weeks_remaining.positive? ? (growth_target_total - ytd) / weeks_remaining : nil

    scenarios = revenue_scenarios(
      ytd: ytd, weeks_remaining: weeks_remaining, last_year_full: last_year_full,
      trimmed13_avg: trimmed13_avg, week_type_avgs: week_type_avgs
    )

    {
      "this_week_revenue"          => round2(this_week),
      "prev_week_revenue"          => round2(prev_week),
      "week_before_prev_revenue"   => round2(week_before_prev),
      "week_over_week_growth_pct"  => round2(growth_pct(this_week, prev_week) || 0),
      "mtd_revenue"                => round2(mtd),
      "ytd_revenue"                => round2(ytd),
      "last_year_same_period_ytd_revenue" => round2(last_year_same_ytd),
      "last_year_full_year_revenue"       => round2(last_year_full),
      "last_year_same_week_data_present"  => last_year_same_ytd.positive?,
      "yoy_growth_pct"             => round2(growth_pct(ytd, last_year_same_ytd) || 0),
      "gap_to_beat_last_year"      => round2(gap),
      "already_beat_last_year"     => gap <= 0,
      "days_remaining_in_year"     => @period.days_remaining_in_year,
      "weeks_remaining_in_year"    => round2(weeks_remaining),
      "required_weekly_revenue_to_beat_last_year" => required_weekly && round2(required_weekly),
      "trailing4_weekly_avg_revenue"  => round2(trailing4_avg),
      "trailing8_weekly_avg_revenue"  => round2(trailing8_avg),
      "trailing13_weekly_avg_revenue" => round2(trailing13_avg),
      "trailing13_trimmed_weekly_avg_revenue" => round2(trimmed13_avg),
      "week_type_historical_avg"   => week_type_avgs,
      "comparable_basis"           => comparable,
      "revenue_concentration"      => concentration,
      "revenue_lines" => {
        "minimum_required_weekly" => required_weekly && round2(required_weekly),
        "safety_line_weekly"      => safety_line && round2(safety_line),
        "growth_target_weekly"    => growth_target_weekly && round2(growth_target_weekly),
        "growth_target_pct"       => GROWTH_TARGET_PCT,
        "safety_buffer_pct"       => SAFETY_BUFFER_PCT,
        "note" => "安全線＝最低警戒線×(1+#{SAFETY_BUFFER_PCT.to_i}%緩衝)；成長目標線基於「較去年全年成長#{GROWTH_TARGET_PCT.to_i}%」的預設參數（非硬編金額，CRM無正式年度目標可讀，可調整此參數）"
      },
      "scenarios" => scenarios,
      "will_beat_last_year_base_case" => scenarios.dig("base", "projected_year_end").to_f >= last_year_full
    }
  end

  def weekly_totals_series(scope, n_weeks)
    (1..n_weeks).map { |n| weekly_total(scope, WeeklyPeriod.for_week_start(@period.week_start - (7 * n)).time_range) }
  end

  def trailing_weekly_avg(scope, n_weeks)
    series = weekly_totals_series(scope, n_weeks)
    series.sum / [series.size, 1].max.to_f
  end

  def trimmed_average(series)
    return 0.0 if series.empty?
    return series.sum / series.size.to_f if series.size <= 2

    sorted = series.sort
    trimmed = sorted[1..-2]
    trimmed.sum / trimmed.size.to_f
  end

  # 分別算出「歷史直播週」與「歷史非直播/非活動自然週」的平均週營收，供樂觀/
  # 保守情境使用——直接借用近26週的實際資料，不對「直播帶動多少」做假設。
  def historical_week_type_averages(scope, lookback_weeks: 26)
    range_start = @period.week_start - (7 * lookback_weeks)
    livestream_dates = Livestream.where(date: range_start...@period.week_start).pluck(:date)
    campaign_dates   = CalendarEvent.where(event_type: "campaign", event_date: range_start...@period.week_start).pluck(:event_date)

    ls_totals = []
    nls_totals = []
    (1..lookback_weeks).each do |n|
      ws = @period.week_start - (7 * n)
      we = ws + 6
      has_ls = livestream_dates.any? { |d| d.between?(ws, we) }
      has_campaign = campaign_dates.any? { |d| d.between?(ws, we) }
      total = weekly_total(scope, ws.beginning_of_day..we.end_of_day)

      if has_ls
        ls_totals << total
      elsif !has_campaign
        nls_totals << total
      end
    end

    {
      "livestream_weekly_avg"       => ls_totals.any? ? round2(ls_totals.sum / ls_totals.size) : 0.0,
      "livestream_sample_weeks"     => ls_totals.size,
      "non_livestream_weekly_avg"   => nls_totals.any? ? round2(nls_totals.sum / nls_totals.size) : 0.0,
      "non_livestream_sample_weeks" => nls_totals.size
    }
  end

  # 找近26週內「同類型」的週（直播週跟直播週比、自然週跟自然週比），算平均
  # 成長率，這是「經營結論」該優先引用的比較基準，而不是無腦的本週vs上週。
  def comparable_basis_stats(week_type, scope)
    starts = WeeklyWeekTypeClassifier.comparable_week_starts(@period, count: 4)
    this_week_total = weekly_total(scope, @period.time_range)

    if starts.empty?
      return {
        "basis_label" => week_type["type_label"], "sample_size" => 0, "growth_pct" => nil,
        "this_week" => round2(this_week_total),
        "basis_note" => "近26週內找不到同類型（#{week_type['type_label']}）的歷史週可比較，目前只能確認本週對上週的原始差異，尚無法判斷是否為基本盤變化"
      }
    end

    totals = starts.map { |ws| weekly_total(scope, WeeklyPeriod.for_week_start(ws).time_range) }
    avg = totals.sum / totals.size.to_f

    {
      "basis_label"   => "近#{totals.size}個#{week_type['type_label']}平均",
      "sample_size"   => totals.size,
      "compare_weeks" => starts,
      "compare_avg"   => round2(avg),
      "this_week"     => round2(this_week_total),
      "growth_pct"    => round2(growth_pct(this_week_total, avg)),
      "basis_note"    => nil
    }
  end

  def revenue_concentration(scope)
    rows = order_level_rows(scope, @period.time_range)
    total = rows.sum { |_, t| t.to_f }
    return concentration_empty if total.zero?

    by_email = Hash.new(0.0)
    rows.each { |email, t| by_email[email] += t.to_f }
    top_customer = by_email.values.max || 0.0

    email_level = ShoplineCustomer.where(email: by_email.keys).pluck(:email, :membership_level).to_h
    by_level = Hash.new(0.0)
    by_email.each { |email, amt| by_level[email_level[email] || "未分類"] += amt }
    top_level_name, top_level_amt = by_level.max_by { |_, v| v } || [nil, 0.0]

    top_product_name, top_product_amt = product_weekly_revenues(scope).max_by { |_, v| v } || [nil, 0.0]
    top_ls_amt = Livestream.where(date: @period.range).maximum(:total_revenue).to_f

    {
      "top_customer_share_pct"   => round2(pct(top_customer, total)),
      "top_level_share_pct"      => round2(pct(top_level_amt, total)), "top_level_name" => top_level_name,
      "top_product_share_pct"    => round2(pct(top_product_amt, total)), "top_product_name" => top_product_name,
      "top_livestream_share_pct" => round2(pct(top_ls_amt, total))
    }
  end

  def product_weekly_revenues(scope)
    CrmProduct.confirmed.where.not(key: EXCLUDED_PRODUCT_KEYS).filter_map do |crm|
      amt = weekly_total(scope.where(crm.matching_sql_pattern), @period.time_range)
      [crm.label, amt] if amt.positive?
    end.to_h
  end

  def concentration_empty
    { "top_customer_share_pct" => nil, "top_level_share_pct" => nil, "top_level_name" => nil,
      "top_product_share_pct" => nil, "top_product_name" => nil, "top_livestream_share_pct" => nil }
  end

  # 三種年底預測情境，各自標明採用公式/期間/週均與成立條件——不是統一套一個
  # 固定倍率。樂觀情境如果查得到「已排定的未來直播場次」（Livestream 已有
  # 未來日期的列），會用「已知場次數」實際估算，不是憑空假設。
  def revenue_scenarios(ytd:, weeks_remaining:, last_year_full:, trimmed13_avg:, week_type_avgs:)
    non_ls_avg = week_type_avgs["non_livestream_weekly_avg"]
    ls_avg = week_type_avgs["livestream_weekly_avg"]

    known_future_livestreams = Livestream.where(date: (@period.week_end + 1)..Date.new(@period.week_end.year, 12, 31)).count
    known_ls_weeks = [known_future_livestreams, weeks_remaining.floor].min
    known_nls_weeks = [weeks_remaining - known_ls_weeks, 0].max

    conservative_projection = ytd + (non_ls_avg * weeks_remaining)
    base_projection = ytd + (trimmed13_avg * weeks_remaining)
    optimistic_projection =
      if known_future_livestreams.positive?
        ytd + (ls_avg * known_ls_weeks) + (non_ls_avg * known_nls_weeks)
      else
        ytd + (trimmed13_avg * 1.15 * weeks_remaining)
      end

    {
      "conservative" => scenario_payload(
        method: "非直播/非活動自然週歷史均速外推（近#{week_type_avgs['non_livestream_sample_weeks']}週樣本），排除直播/活動帶動效果",
        weekly_rate: non_ls_avg, projection: conservative_projection, last_year_full: last_year_full,
        condition: "剩餘週數都以「沒有直播/活動加持」的基本盤表現估算，若已知有缺貨中的主力商品会進一步壓低此情境"
      ),
      "base" => scenario_payload(
        method: "近13週去極值平均外推（排除最高與最低各1週後取平均，降低單一直播/促銷高峰影響）",
        weekly_rate: trimmed13_avg, projection: base_projection, last_year_full: last_year_full,
        condition: "假設接下來的週次表現跟近13週的「去極值後」常態相近"
      ),
      "optimistic" => scenario_payload(
        method: known_future_livestreams.positive? ? "已知剩餘#{known_future_livestreams}場排定直播用歷史直播週均速估算，其餘週用非直播週均速估算" :
                                                       "近13週去極值平均 × 1.15（CRM 查無已排定的未來直播場次，只能用比例假設，非精算）",
        weekly_rate: known_future_livestreams.positive? ? nil : round2(trimmed13_avg * 1.15),
        projection: optimistic_projection, last_year_full: last_year_full,
        condition: known_future_livestreams.positive? ? "已知未來直播場次#{known_future_livestreams}場如期舉行且表現貼近歷史直播週均值" : "剩餘週次表現能維持近期高點的1.15倍，屬於樂觀假設，成立條件不明確"
      )
    }
  end

  def scenario_payload(method:, weekly_rate:, projection:, last_year_full:, condition:)
    gap = last_year_full - projection
    {
      "method"              => method,
      "weekly_rate_used"    => weekly_rate && round2(weekly_rate),
      "projected_year_end"  => round2(projection),
      "vs_last_year"        => round2(-gap),
      "beats_last_year"     => gap <= 0,
      "success_condition"   => condition
    }
  end

  # ── 資料品質彙總（給風險偵測跟附錄用）───────────────────────────
  def build_data_quality(product_repurchase, membership)
    stale_products = product_repurchase["products"].select { |p| p["cycles_stale"] }
    last_year_same_week_orders = ShoplineOrder.valid_paid.where(
      order_date: @period.last_year_same_week_range.begin.beginning_of_day..@period.last_year_same_week_range.end.end_of_day
    ).count

    stale_livestreams = Livestream.where(date: (@period.week_end - 13)..@period.week_end)
                                   .select { |ls| ls.stats_refreshed_at.nil? || ls.stats_refreshed_at.to_date < ls.date }

    {
      "product_cycle_contradiction_detected" => product_repurchase["contradiction_detected"],
      "stale_product_cycles" => stale_products.map { |p| { "product_key" => p["product_key"], "label" => p["label"], "refreshed_at" => p["cycles_refreshed_at"] } },
      "membership_unclassified_revenue_pct"  => membership.dig("reconciliation", "unclassified_pct"),
      "last_year_same_week_order_count"      => last_year_same_week_orders,
      "last_year_same_week_data_incomplete"  => last_year_same_week_orders.zero?,
      "stale_livestream_stats" => stale_livestreams.map { |ls| { "date" => ls.date, "title" => ls.title } }
    }
  end

  # ── 資料缺口登記表（附錄用）──────────────────────────────────────
  # 2026-09-15 второй輪修正：舊版把「沒有資料」的警語散落在 membership/
  # order_quality/week_type 好幾個地方,還規定 AI 要逐字引用,導致正文充滿
  # 「資料不足/需人工確認」。改成集中登記在這裡，每個缺口只出現一次、分
  # critical(會讓核心結論站不住)/important(能判斷方向但不能確認原因)/
  # supplementary(不影響本週決策)三級——只有 critical 才要求 AI 在正文提示，
  # important/supplementary 一律只出現在附錄。「permanent」代表 CRM 結構性
  # 缺口（每週都一樣），「this_week」代表本週才發生的資料品質例外（過期快取/
  # 矛盾/去年同期缺資料等）。
  #
  # completeness_score 只統計 permanent 缺口，避免單週的暫時性异常（例如快取
  # 剛好還沒刷新）讓分數忽高忽低——那類例外已經個別出現在 this_week 缺口
  # 跟 WeeklyRiskFlagDetector 的 data_quality 風險裡，分數不需要重複反映。
  def build_data_gaps(week_type, revenue_progress, membership, data_quality)
    permanent = [
      { topic: "會員等級升降門檻規則", available: "實際升降級紀錄、各卡別活躍率/客單價/最近購買日", missing: "Shopline官方門檻金額",
        impact: "important", proxy_used: "用升降級紀錄與活躍率判斷會員健康度方向", suggested_integration: "跟Shopline要一份門檻規則表或API" },
      { topic: "前端流量與轉換漏斗", available: "有效訂單數、付款失敗率、新客訂單數", missing: "網站流量、商品頁瀏覽、加購、結帳啟動",
        impact: "important", proxy_used: "用「成交結果」（訂單/買家/營收）判斷，不推論轉換率", suggested_integration: "串接GA4或Shopline流量報表" },
      { topic: "廣告投放與成本", available: "新客人數、新客營收、新客占比", missing: "廣告花費、ROAS、素材成效",
        impact: "supplementary", proxy_used: "新客量能變化間接反映拉新入口強弱", suggested_integration: "串接廣告平台API或每週手動匯入花費" },
      { topic: "商品成本與毛利", available: "營收、買家數、回購率", missing: "商品成本、毛利率",
        impact: "supplementary", proxy_used: "商品優先順序以營收/買家/回購機會評估，不代表利潤排序", suggested_integration: "建立商品成本主檔" },
      { topic: "活動規模分級", available: "活動是否存在（calendar_events campaign）", missing: "活動規模（大型檔期vs一般促銷）",
        impact: "supplementary", proxy_used: "只標記「活動週」，不細分規模", suggested_integration: "在活動行事曆加一個規模欄位" },
      { topic: "直播觀看數與互動率", available: "直播營收、訂單數、買家數、客單價、卡別分布", missing: "觀看人數、互動率",
        impact: "supplementary", proxy_used: "只判斷「成交表現」，不判斷「流量或轉換率」", suggested_integration: "串接直播平台後台數據" },
      { topic: "精確庫存週轉", available: "庫存狀態（有貨/低庫存/缺貨/預購）", missing: "精確庫存量與週轉天數",
        impact: "supplementary", proxy_used: "缺貨標記+本週銷量=0時，判斷「可能受缺貨影響」", suggested_integration: "串接倉儲系統庫存數字" }
    ]

    this_week = []
    if data_quality["last_year_same_week_data_incomplete"]
      this_week << { topic: "去年同期比較資料", available: "今年本週資料", missing: "去年同一週完全沒有訂單記錄", impact: "important",
                      proxy_used: "YoY比較本週無法使用，改用近13週去極值平均等短期基準判斷", suggested_integration: "檢查去年資料是否有匯入缺漏" }
    end
    if Array(data_quality["stale_product_cycles"]).any?
      this_week << { topic: "商品回購比對快取", available: "逾期人數（依上次刷新時的快照）", missing: "本週回購比對結果",
                      impact: "critical", proxy_used: "無，已將受影響數字標示為資料不足", suggested_integration: "確認 ops:weekly_briefing 排程有正常執行" }
    end
    if data_quality["product_cycle_contradiction_detected"]
      this_week << { topic: "商品回購資料一致性", available: "舊客購買人數", missing: "商品層級回購比對結果（本週互相矛盾）", impact: "critical",
                      proxy_used: "無，已將受影響數字標示為資料不足", suggested_integration: "同上，確認排程/快取正常" }
    end
    if revenue_progress.dig("comparable_basis", "basis_note").present?
      this_week << { topic: "可比較歷史週基準", available: "本週與上週原始營收", missing: "近26週內同類型（#{week_type['type_label']}）的歷史週",
                      impact: "important", proxy_used: "只能用本週vs上週的原始差異判斷方向，信心降級", suggested_integration: "累積更多同類型週次後會自動改善" }
    end
    if Array(data_quality["stale_livestream_stats"]).any?
      this_week << { topic: "直播統計快取", available: "直播訂單/營收原始資料", missing: "最新統計快取（可能落後於實際訂單）", impact: "important",
                      proxy_used: "直接查詢當場訂單原始資料當佐證，統計數字僅供參考", suggested_integration: "重跑 livestreams:stats:refresh" }
    end
    if week_type["campaign_size_note"].present?
      this_week << { topic: "本週活動規模", available: "活動存在與日期", missing: "活動規模分級", impact: "supplementary",
                      proxy_used: "只標記本週是活動週，不判斷規模大小", suggested_integration: nil }
    end

    # metrics 全篇慣例用字串鍵（供 to_json 序列化跟 DB 存讀一致），這裡的字面量
    # hash 為求可讀性用符號鍵寫，最後統一轉成字串鍵，避免呼叫端用 g["topic"]
    # 卻因為鍵是 symbol 而永遠讀不到值。
    gaps = (permanent.map { |g| g.merge(scope: "permanent") } + this_week.map { |g| g.merge(scope: "this_week") })
           .map(&:stringify_keys)
    # completeness_score：permanent 缺口全部視為「未整合」扣分，分母是
    # 「已知會用到的資料主題總數」＝ permanent 缺口數 + 本報告已經有資料可用的
    # 核心主題數（營收/訂單/新舊客/會員卡別/直播成交/商品回購，共6項固定視為
    # 已具備）。分數只用來提醒，不做為是否產生報告的門檻。
    core_available_topics = 6
    total_topics = core_available_topics + permanent.size
    completeness_score = round2((core_available_topics.to_f / total_topics) * 100)

    {
      "completeness_score" => completeness_score,
      "score_note"         => "分數僅供參考，不作為是否產生報告的門檻；即使未達100%，本週報告仍須提出經營判斷與決策建議。",
      "gaps"               => gaps
    }
  end
end

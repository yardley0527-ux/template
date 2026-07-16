# frozen_string_literal: true

# 消費排行榜的資料層：一次聚合 SQL 算出每會員的年度金額、同期金額、
# 首購/最近消費日與訂單數，再於記憶體中完成排名、動能與摘要卡統計。
#
# 口徑（沿用破8000慣例）：只算「已付款」訂單；每張訂單金額取 total_amount
# （同訂單各商品行重複同一值，取 MAX），缺失時以商品行 checkout_amount 加總回推；
# 會員以 email（去空白、不分大小寫）為準。
#
# 「2025 同期」＝ 2025/01/01 至「去年的今天」（含當天整日）。閏日 2/29 在
# 前一年不存在時取 2/28（Ruby Date#prev_year 的行為，見 same_period_end_date）。
#
# 動能優先序（條件互斥，依序取第一個成立者）：
#   1. NEW      — 第一筆已付款訂單落在 2026 年
#   2. 回流     — 2024 以前買過、2025 全年沒買、2026 有買
#   3. 超越去年 — 2025 有消費且 2026 累積已 >= 2025 全年
#   4. 流失警訊 — 2025 同期有消費且 2026 至今 < 同期 × 0.5
#   5. 穩定     — 以上皆非
# （舊版 NEW＝「2025 沒買、2026 有買」會把回流客誤判成新客，本版以首購日區分。）
class SpendingRankingsReport
  TABS = {
    "y2025" => { title: "2025 年度消費排行榜", subtitle: "統計 2025 全年度消費金額，取前 100 名", limit: 100, sort_key: :amount_2025 },
    "y2026" => { title: "2026 年度累積消費排行榜", subtitle: "統計 2026 年截至目前為止的累積消費金額，取前 100 名", limit: 100, sort_key: :amount_2026 },
    "total" => { title: "總累積消費排行榜", subtitle: "2025 消費金額 + 2026 累積消費金額合併計算，取前 200 名", limit: 200, sort_key: :amount_total }
  }.freeze

  COOLING_RATIO   = 0.5   # 2026 至今 < 2025 同期 × 0.5 → 流失警訊
  RISING_TRENDS   = %i[new returning surpassed].freeze
  LIVESTREAM_WINDOW_DAYS = 3 # 沿用直播來源分析（livestream_strategy#sources）的直播歸因窗（直播日起 3 天內下單）

  attr_reader :today

  def initialize(today: Date.current)
    @today = today
  end

  # ── 日期界線 ──────────────────────────────────────────────

  def y2025_start = Time.zone.local(2025, 1, 1)
  def y2026_start = Time.zone.local(2026, 1, 1)
  def y2027_start = Time.zone.local(2027, 1, 1)

  # 去年的今天（整日計入）。2/29 在去年不存在時，Date#prev_year 回 2/28。
  def same_period_end_date
    today.prev_year
  end

  # SQL 排除性上界：同期截止日的隔天 0 點
  def same_period_end_exclusive
    d = same_period_end_date + 1
    Time.zone.local(d.year, d.month, d.day)
  end

  # ── 全量彙總 ──────────────────────────────────────────────

  # { email => { email:, customer_id:, amount_2025:, amount_2026:, amount_2025_ytd:,
  #              amount_total:, orders_2025:, orders_2026:, first_paid_order_at:,
  #              last_paid_order_at:, last_2025_at:, last_2026_at: } }
  def totals
    @totals ||= ActiveRecord::Base.connection.select_all(totals_sql).to_a.each_with_object({}) do |r, h|
      a2025 = r["amount_2025"].to_f.round
      a2026 = r["amount_2026"].to_f.round
      h[r["email_key"]] = {
        email: r["email_key"],
        customer_id: r["customer_id"],
        amount_2025: a2025,
        amount_2026: a2026,
        amount_2025_ytd: r["amount_2025_ytd"].to_f.round,
        amount_total: a2025 + a2026,
        orders_2025: r["orders_2025"].to_i,
        orders_2026: r["orders_2026"].to_i,
        first_paid_order_at: parse_time(r["first_paid_order_at"]),
        last_paid_order_at: parse_time(r["last_paid_order_at"]),
        last_2025_at: parse_time(r["last_2025_at"]),
        last_2026_at: parse_time(r["last_2026_at"])
      }
    end
  end

  # 三個榜（前 N 名，已標 :rank）。排序 tie-breaker：金額 DESC →
  # 該期間最近已付款日 DESC → customer id ASC（無 id 者排後，最後以 email 穩定）。
  def rankings
    @rankings ||= TABS.transform_values do |config|
      ranked_list(config[:sort_key]).first(config[:limit])
    end
  end

  # 全量排名（不只前 100）：email => rank。2025/2026 使用相同 tie-breaker。
  def full_rank_2025 = (@full_rank_2025 ||= build_rank_map(:amount_2025))
  def full_rank_2026 = (@full_rank_2026 ||= build_rank_map(:amount_2026))

  # ── 動能 ─────────────────────────────────────────────────

  def trend_for(t)
    if t[:first_paid_order_at] && t[:first_paid_order_at] >= y2026_start
      :new
    elsif t[:amount_2025].zero? && t[:amount_2026].positive? &&
          t[:first_paid_order_at] && t[:first_paid_order_at] < y2025_start
      :returning
    elsif t[:amount_2025].positive? && t[:amount_2026] >= t[:amount_2025]
      :surpassed
    elsif cooling?(t)
      :cooling
    else
      :stable
    end
  end

  def cooling?(t)
    t[:amount_2025_ytd].positive? && t[:amount_2026] < t[:amount_2025_ytd] * COOLING_RATIO
  end

  # ── 摘要卡（永遠全量，不受 tab/搜尋/篩選/分頁影響）────────────

  def summary
    @summary ||= begin
      cooling = rankings["y2025"].select { |t| cooling?(t) }
      rising  = rankings["y2026"].select { |t| RISING_TRENDS.include?(trend_for(t)) }
      top200_sum = rankings["total"].sum { |t| t[:amount_total] }
      company_total = totals.values.sum { |t| t[:amount_total] }

      top100_2026_sum = rankings["y2026"].sum { |t| t[:amount_2026] }
      top100_2025_ytd_sum = totals.values
                                  .select { |t| t[:amount_2025_ytd].positive? }
                                  .sort_by { |t| [-t[:amount_2025_ytd], stable_tail(t, :last_2025_at)].flatten }
                                  .first(100)
                                  .sum { |t| t[:amount_2025_ytd] }

      {
        cooling_count: cooling.size,
        cooling_no_repurchase: cooling.count { |t| t[:amount_2026].zero? },
        rising_count: rising.size,
        rising_new: rising.count { |t| trend_for(t) == :new },
        rising_returning: rising.count { |t| trend_for(t) == :returning },
        total_count: rankings["total"].size,
        total_amount: top200_sum,
        total_share: company_total.positive? ? (top200_sum * 100.0 / company_total).round(1) : 0.0,
        top100_2026_sum: top100_2026_sum,
        top100_2025_ytd_sum: top100_2025_ytd_sum,
        top100_yoy_change: top100_2026_sum - top100_2025_ytd_sum,
        top100_yoy_rate: top100_2025_ytd_sum.positive? ? ((top100_2026_sum - top100_2025_ytd_sum) * 100.0 / top100_2025_ytd_sum).round(1) : nil
      }
    end
  end

  # ── 名單客戶快照（姓名/IG/卡別）───────────────────────────────

  def customer_snapshots(emails)
    return {} if emails.empty?

    quoted = emails.map { |e| ActiveRecord::Base.connection.quote(e) }.join(", ")
    sql = <<~SQL
      WITH sc AS (
        SELECT DISTINCT ON (LOWER(TRIM(email))) LOWER(TRIM(email)) AS email_key, id, full_name, membership_level
        FROM shopline_customers
        WHERE LOWER(TRIM(email)) IN (#{quoted})
        ORDER BY LOWER(TRIM(email)), id
      ),
      ig AS (
        SELECT DISTINCT ON (LOWER(TRIM(email))) LOWER(TRIM(email)) AS email_key, instagram_account
        FROM shopline_orders
        WHERE LOWER(TRIM(email)) IN (#{quoted})
          AND instagram_account IS NOT NULL AND instagram_account <> ''
        ORDER BY LOWER(TRIM(email)), order_date DESC
      )
      SELECT sc.email_key, sc.id, sc.full_name, sc.membership_level, ig.instagram_account
      FROM sc LEFT JOIN ig ON ig.email_key = sc.email_key
    SQL

    ActiveRecord::Base.connection.select_all(sql).to_a.index_by { |r| r["email_key"] }
  end

  # ── 展開列管理指標（僅當頁 emails，全部批次查詢，無 N+1）──────────

  # period: :y2025 / :y2026 / :total（訂單數、客單、回購、最常買產品的統計期間）
  def management_details(emails, period:, customer_ids_by_email: {})
    return {} if emails.empty?

    range = period_range(period)
    top_products   = top_products_for(emails, range)
    livestream_map = last_livestream_for(emails)
    cps_map        = purchase_summaries_for(emails)
    profile_map    = profiles_for(customer_ids_by_email)
    follow_up_map  = follow_ups_for(cps_map)

    emails.index_with do |email|
      t = totals[email] || {}
      orders = period_order_count(t, period)
      amount = period_amount(t, period)
      profile = profile_map[customer_ids_by_email[email]]
      cps = cps_map[email]
      {
        order_count: orders,
        avg_order: orders.positive? ? (amount.to_f / orders).round : nil,
        repurchase_count: [orders - 1, 0].max,
        top_product: top_products[email],
        first_paid_order_at: t[:first_paid_order_at],
        last_livestream_date: livestream_map[email],
        line_status: cps.nil? ? "無法判定" : (cps["line_bound"] ? "已綁定" : "未綁定"),
        ig_status: profile.nil? ? "無法判定" : (profile["follows_chloe_ig"] ? "已追蹤" : "未追蹤"),
        crm_status: crm_status_for(profile, follow_up_map[cps&.fetch("identity_key", nil)])
      }
    end
  end

  def period_range(period)
    case period
    when :y2025 then y2025_start...y2026_start
    when :y2026 then y2026_start...y2027_start
    else             y2025_start...y2027_start
    end
  end

  private

  def period_order_count(t, period)
    case period
    when :y2025 then t[:orders_2025].to_i
    when :y2026 then t[:orders_2026].to_i
    else             t[:orders_2025].to_i + t[:orders_2026].to_i
    end
  end

  def period_amount(t, period)
    case period
    when :y2025 then t[:amount_2025].to_f
    when :y2026 then t[:amount_2026].to_f
    else             t[:amount_total].to_f
    end
  end

  def ranked_list(sort_key)
    last_key = sort_key == :amount_2025 ? :last_2025_at : (sort_key == :amount_2026 ? :last_2026_at : :last_paid_order_at)
    totals.values
          .select { |t| t[sort_key].positive? }
          .sort_by { |t| [-t[sort_key], stable_tail(t, last_key)].flatten }
          .each_with_index.map { |t, i| t.merge(rank: i + 1) }
  end

  def build_rank_map(sort_key)
    key = sort_key == :amount_2025 ? :last_2025_at : :last_2026_at
    totals.values
          .select { |t| t[sort_key].positive? }
          .sort_by { |t| [-t[sort_key], stable_tail(t, key)].flatten }
          .each_with_index.each_with_object({}) { |(t, i), h| h[t[:email]] = i + 1 }
  end

  # tie-breaker：最近已付款消費日 DESC → customer id ASC（無 id 排後）→ email ASC
  def stable_tail(t, last_key)
    [-(t[last_key]&.to_i || 0), t[:customer_id] ? 0 : 1, t[:customer_id].to_i, t[:email]]
  end

  def totals_sql
    ActiveRecord::Base.sanitize_sql_array([<<~SQL, { y25: y2025_start, y26: y2026_start, y27: y2027_start, same_end: same_period_end_exclusive }])
      WITH order_totals AS (
        SELECT LOWER(TRIM(email)) AS email_key,
               order_number,
               MIN(order_date) AS order_date,
               COALESCE(MAX(NULLIF(total_amount, 0)), SUM(COALESCE(checkout_amount, 0))) AS amount
        FROM shopline_orders
        WHERE payment_status = '已付款'
          AND order_number IS NOT NULL AND order_number <> ''
          AND email IS NOT NULL AND email <> ''
          AND order_date IS NOT NULL
        GROUP BY LOWER(TRIM(email)), order_number
      ),
      agg AS (
        SELECT email_key,
               MIN(order_date) AS first_paid_order_at,
               MAX(order_date) AS last_paid_order_at,
               COALESCE(SUM(amount) FILTER (WHERE order_date >= :y25 AND order_date < :y26), 0) AS amount_2025,
               COUNT(*)            FILTER (WHERE order_date >= :y25 AND order_date < :y26)      AS orders_2025,
               MAX(order_date)     FILTER (WHERE order_date >= :y25 AND order_date < :y26)      AS last_2025_at,
               COALESCE(SUM(amount) FILTER (WHERE order_date >= :y26 AND order_date < :y27), 0) AS amount_2026,
               COUNT(*)            FILTER (WHERE order_date >= :y26 AND order_date < :y27)      AS orders_2026,
               MAX(order_date)     FILTER (WHERE order_date >= :y26 AND order_date < :y27)      AS last_2026_at,
               COALESCE(SUM(amount) FILTER (WHERE order_date >= :y25 AND order_date < :same_end), 0) AS amount_2025_ytd
        FROM order_totals
        GROUP BY email_key
      )
      SELECT agg.*, sc.id AS customer_id
      FROM agg
      LEFT JOIN (
        SELECT DISTINCT ON (LOWER(TRIM(email))) LOWER(TRIM(email)) AS email_key, id
        FROM shopline_customers
        ORDER BY LOWER(TRIM(email)), id
      ) sc USING (email_key)
    SQL
  end

  # 期間內每人最常買產品：數量 DESC → 金額 DESC → 標準化名稱 ASC。
  # 產品名稱以 ProductNameMapping（confirmed_alias）解析成 CrmProduct label；
  # 無法解析的原始名稱歸入「未分類」。
  def top_products_for(emails, range)
    quoted = emails.map { |e| ActiveRecord::Base.connection.quote(e) }.join(", ")
    sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL, { from: range.begin, to: range.end }])
      SELECT LOWER(TRIM(email)) AS email_key, product_name,
             SUM(COALESCE(quantity, 0)) AS qty, SUM(COALESCE(checkout_amount, 0)) AS amount
      FROM shopline_orders
      WHERE payment_status = '已付款'
        AND order_number IS NOT NULL AND order_number <> ''
        AND order_date >= :from AND order_date < :to
        AND LOWER(TRIM(email)) IN (#{quoted})
      GROUP BY LOWER(TRIM(email)), product_name
    SQL
    lines = ActiveRecord::Base.connection.select_all(sql).to_a
    mapping = ProductNameResolver.resolve_batch(lines.map { |l| l["product_name"] })

    per_email = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = { qty: 0, amount: 0.0 } } }
    lines.each do |l|
      label = mapping[l["product_name"].to_s.strip]&.label || "未分類"
      entry = per_email[l["email_key"]][label]
      entry[:qty] += l["qty"].to_i
      entry[:amount] += l["amount"].to_f
    end

    per_email.transform_values do |products|
      products.min_by { |label, v| [-v[:qty], -v[:amount], label] }&.first
    end
  end

  # 最近參與直播：沿用直播來源分析（livestream_strategy#sources）的歸因窗 —
  # 訂單日落在某場直播日起 3 天內，取最近一場。無精確的個人參與紀錄，
  # 此為「直播檔期購買」推定，非觀看名單。
  def last_livestream_for(emails)
    dates = Livestream.pluck(:date).map(&:to_date).sort
    return {} if dates.empty?

    order_dates = ShoplineOrder.valid_paid
                               .where("LOWER(TRIM(email)) IN (?)", emails)
                               .where(order_date: y2025_start..)
                               .pluck(Arel.sql("LOWER(TRIM(email))"), :order_date)
    result = {}
    order_dates.group_by(&:first).each do |email, pairs|
      hit = pairs.map { |p| p.last.to_date }.uniq.sort.reverse.lazy.map { |od|
        dates.select { |d| d <= od && od <= d + LIVESTREAM_WINDOW_DAYS }.max
      }.find(&:itself)
      result[email] = hit
    end
    result
  end

  def purchase_summaries_for(emails)
    quoted = emails.map { |e| ActiveRecord::Base.connection.quote(e) }.join(", ")
    sql = <<~SQL
      SELECT DISTINCT ON (LOWER(TRIM(email))) LOWER(TRIM(email)) AS email_key, identity_key, line_bound
      FROM customer_purchase_summaries
      WHERE LOWER(TRIM(email)) IN (#{quoted})
      ORDER BY LOWER(TRIM(email)), id
    SQL
    ActiveRecord::Base.connection.select_all(sql).to_a.index_by { |r| r["email_key"] }
  end

  def profiles_for(customer_ids_by_email)
    ids = customer_ids_by_email.values.compact
    return {} if ids.empty?

    CustomerProfile.where(shopline_customer_id: ids)
                   .pluck(:shopline_customer_id, :follows_chloe_ig, :stickiness_maintained, :stickiness_followed_up_at)
                   .each_with_object({}) do |(cid, ig, maintained, followed_at), h|
      h[cid] = { "follows_chloe_ig" => ig, "stickiness_maintained" => maintained, "stickiness_followed_up_at" => followed_at }
    end
  end

  def follow_ups_for(cps_map)
    keys = cps_map.values.map { |c| c["identity_key"] }.compact
    return {} if keys.empty?

    HighSpenderFollowUp.where(identity_key: keys)
                       .group(:identity_key)
                       .maximum(:followed_up_at)
  end

  # CRM 跟進狀態：沿用黏著度分析與破萬追蹤的既有欄位，不另建狀態系統。
  def crm_status_for(profile, last_follow_up_at)
    return "已維護" if profile && profile["stickiness_maintained"]

    last = [profile&.fetch("stickiness_followed_up_at", nil), last_follow_up_at].compact.max
    last ? "追蹤中（#{last.to_date.strftime('%Y/%m/%d')}）" : "尚未建立"
  end

  # select_all 回傳的 timestamp 是 DB 原值（UTC），沒經過 AR 的時區轉換，
  # 需先視為 UTC 再轉回 Time.zone（Taipei），否則日期會差 8 小時。
  def parse_time(v)
    return nil if v.nil?

    t = v.is_a?(String) ? Time.find_zone!("UTC").parse(v) : v
    t.in_time_zone
  end
end

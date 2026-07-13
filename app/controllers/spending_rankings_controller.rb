# frozen_string_literal: true

# 消費排行榜：三個排行榜 tab —
#   2025 年度消費排行榜（依 2025 全年消費金額，前 100 名）
#   2026 年度累積消費排行榜（依 2026 截至目前累積金額，前 100 名）
#   總累積消費排行榜（2025 + 2026 合計，前 200 名）
# 口徑：只算「已付款」訂單；每張訂單金額取 total_amount（同訂單各商品行重複同一值，取 MAX），
# 缺失時以商品行 checkout_amount 加總回推，再依會員（email）按年度彙總。
class SpendingRankingsController < ApplicationController
  TABS = {
    "y2025" => { title: "2025 年度消費排行榜", subtitle: "統計 2025 全年度消費金額，取前 100 名", limit: 100, sort_key: :amount_2025 },
    "y2026" => { title: "2026 年度累積消費排行榜", subtitle: "統計 2026 年截至目前為止的累積消費金額，取前 100 名", limit: 100, sort_key: :amount_2026 },
    "total" => { title: "總累積消費排行榜", subtitle: "2025 消費金額 + 2026 累積消費金額合併計算，取前 200 名", limit: 200, sort_key: :amount_total }
  }.freeze

  def index
    @tab = TABS.key?(params[:tab]) ? params[:tab] : "y2025"
    config = TABS[@tab]

    totals = yearly_totals_by_email
    sort_key = config[:sort_key]
    ranked = totals.values
                   .select { |t| t[sort_key].positive? }
                   .sort_by { |t| -t[sort_key] }
                   .first(config[:limit])

    customers = customer_snapshots(ranked.map { |t| t[:email] })
    @rows = ranked.each_with_index.map do |t, i|
      c = customers[t[:email]] || {}
      {
        rank: i + 1,
        email: t[:email],
        full_name: c["full_name"],
        instagram_account: c["instagram_account"],
        membership_level: c["membership_level"],
        shopline_customer_id: c["id"],
        amount_2025: t[:amount_2025],
        amount_2026: t[:amount_2026],
        amount_total: t[:amount_total]
      }
    end

    @tab_config = config
  end

  private

  # 每會員的 2025 / 2026 / 合計消費金額。
  # 先在訂單層級決定金額與年度（同訂單商品行共用 total_amount，取 MAX；
  # 年度以訂單日期落點判斷），再彙總到會員層級。
  def yearly_totals_by_email
    y2025_start = Time.zone.local(2025, 1, 1)
    y2026_start = Time.zone.local(2026, 1, 1)
    y2027_start = Time.zone.local(2027, 1, 1)

    sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL2, y2025_start, y2027_start, y2026_start, y2026_start])
      WITH order_totals AS (
        SELECT LOWER(TRIM(email)) AS email_key,
               order_number,
               MIN(order_date) AS order_date,
               COALESCE(MAX(NULLIF(total_amount, 0)), SUM(COALESCE(checkout_amount, 0))) AS amount
        FROM shopline_orders
        WHERE payment_status = '已付款'
          AND order_number IS NOT NULL AND order_number <> ''
          AND email IS NOT NULL AND email <> ''
          AND order_date >= ? AND order_date < ?
        GROUP BY LOWER(TRIM(email)), order_number
      )
      SELECT email_key,
             SUM(CASE WHEN order_date < ? THEN amount ELSE 0 END) AS amount_2025,
             SUM(CASE WHEN order_date >= ? THEN amount ELSE 0 END) AS amount_2026
      FROM order_totals
      GROUP BY email_key
    SQL2

    ActiveRecord::Base.connection.select_all(sql).to_a.each_with_object({}) do |r, h|
      a2025 = r["amount_2025"].to_f.round
      a2026 = r["amount_2026"].to_f.round
      h[r["email_key"]] = { email: r["email_key"], amount_2025: a2025, amount_2026: a2026, amount_total: a2025 + a2026 }
    end
  end

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
end

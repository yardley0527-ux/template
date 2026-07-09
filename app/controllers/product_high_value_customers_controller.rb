# frozen_string_literal: true

# 產品高破萬次數客人：依產品系列分組，列出「單筆訂單中該系列商品金額滿 1 萬」
# 次數多的客人，依破萬次數排序 — 找出各產品可以推大單的客人。
# 口徑（算法 A）：同一張訂單內該系列各商品行 checkout_amount 加總 >= 10,000 才算破萬一次；
# 整張訂單破萬但該系列只買一點的不算。
class ProductHighValueCustomersController < ApplicationController
  THRESHOLD = 10_000
  LEVEL_RANK = { "黑卡" => 1, "金卡" => 2, "銀卡" => 3, "白卡" => 4, "一般會員" => 5 }.freeze

  def index
    @start_date = parse_date(params[:start_date]) || Date.new(Date.current.year, 1, 1)
    @end_date   = parse_date(params[:end_date])   || Date.current
    @end_date   = @start_date if @end_date < @start_date

    all_groups = build_groups
    @product_summary = all_groups.map { |g| { series: g[:series], count: g[:rows].size } }
    @series_filter   = all_groups.any? { |g| g[:series] == params[:series] } ? params[:series] : nil
    @groups = @series_filter ? all_groups.select { |g| g[:series] == @series_filter } : all_groups
  end

  private

  def parse_date(str)
    Date.iso8601(str.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def product_series(name)
    name.to_s.match(/\A([^\d]+)/)&.captures&.first&.strip.presence || name.to_s
  end

  def build_groups
    lines = ShoplineOrder.valid_paid
                         .where(order_date: @start_date.beginning_of_day..@end_date.end_of_day)
                         .pluck(:order_number, :email, :product_name, :checkout_amount, :order_date)

    # 同一張訂單內，該系列所有商品行金額加總
    per_order_series = Hash.new { |h, k| h[k] = { amount: 0.0, date: nil } }
    lines.each do |order_num, email, product_name, checkout_amount, order_date|
      series = product_series(product_name)
      next if series.blank?

      entry = per_order_series[[order_num, email.to_s.strip.downcase, series]]
      entry[:amount] += checkout_amount.to_f
      entry[:date] = order_date if entry[:date].nil? || order_date > entry[:date]
    end

    # 破萬的 (訂單, 客人, 系列) → 依 (系列, 客人) 統計次數
    stats = Hash.new { |h, k| h[k] = { count: 0, total: 0, last_date: nil } }
    per_order_series.each do |(_order_num, email, series), entry|
      next if entry[:amount] < THRESHOLD

      s = stats[[series, email]]
      s[:count] += 1
      s[:total] += entry[:amount].round
      s[:last_date] = entry[:date] if s[:last_date].nil? || entry[:date] > s[:last_date]
    end
    return [] if stats.empty?

    customers = customer_snapshots(stats.keys.map(&:last).uniq)

    grouped = stats.group_by { |(series, _email), _s| series }
    grouped.map do |series, entries|
      rows = entries.map do |(_series, email), s|
        c = customers[email] || {}
        # 客人整體平均客單價：累計消費 / 總訂單數（shopline_customers 匯入欄位）
        avg_order = c["order_count"].to_i.positive? ? (c["total_amount"].to_f / c["order_count"].to_i).round : nil
        {
          email: email,
          full_name: c["full_name"],
          instagram_account: c["instagram_account"],
          membership_level: c["membership_level"],
          shopline_customer_id: c["id"],
          count: s[:count],
          total: s[:total],
          avg_order: avg_order,
          last_date: s[:last_date]
        }
      end
      rows.sort_by! { |r| [-r[:count], -r[:total], LEVEL_RANK.fetch(r[:membership_level], 6)] }
      { series: series, rows: rows }
    end.sort_by { |g| [-g[:rows].size, -g[:rows].sum { |r| r[:total] }] }
  end

  def customer_snapshots(emails)
    return {} if emails.empty?

    quoted = emails.map { |e| ActiveRecord::Base.connection.quote(e) }.join(", ")
    sql = <<~SQL
      WITH sc AS (
        SELECT DISTINCT ON (LOWER(TRIM(email))) LOWER(TRIM(email)) AS email_key, id, full_name, membership_level,
               total_amount, order_count
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
      SELECT sc.email_key, sc.id, sc.full_name, sc.membership_level, sc.total_amount, sc.order_count, ig.instagram_account
      FROM sc LEFT JOIN ig ON ig.email_key = sc.email_key
    SQL

    ActiveRecord::Base.connection.select_all(sql).to_a.index_by { |r| r["email_key"] }
  end
end

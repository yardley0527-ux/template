# frozen_string_literal: true

# 代謝錠回購客人中，同時有買清纖粉的名單。
# 「代謝錠回購」沿用 CustomerSeriesLoyaltyRefreshService 建立的官方 series 忠誠度快取
# （customer_series_loyalties，只收錄該系列已回購 >=2 次的人），「清纖粉購買次數」則
# 直接查 shopline_orders，因為快取表不收錄只買過一次的人，無法反映「有沒有買過」。
class MetabolismQingxianCustomersController < ApplicationController
  MEMBERSHIP_RANK_SQL = <<~SQL.squish
    CASE COALESCE(sc.membership_level, '')
      WHEN '黑卡' THEN 1
      WHEN '金卡' THEN 2
      WHEN '銀卡' THEN 3
      WHEN '白卡' THEN 4
      WHEN '一般會員' THEN 5
      ELSE 6
    END
  SQL

  def index
    @start_date = parse_date(params[:start_date]) || Date.new(Date.current.year, 1, 1)
    @end_date   = parse_date(params[:end_date])   || Date.current

    @customers = query_customers(@start_date, @end_date)
  end

  def export
    start_date = parse_date(params[:start_date]) || Date.new(Date.current.year, 1, 1)
    end_date   = parse_date(params[:end_date])   || Date.current
    customers  = query_customers(start_date, end_date)

    require "csv"

    csv = CSV.generate(encoding: "UTF-8") do |rows|
      rows << ["姓名", "IG", "代謝錠回購次數", "清纖粉購買次數", "總訂單數", "總消費", "會員等級"]
      customers.each do |c|
        rows << [
          c["full_name"],
          c["instagram_account"],
          c["metabolism_repurchase_count"],
          c["qingxian_count"],
          c["total_orders"],
          c["total_spend"],
          c["membership_level"]
        ]
      end
    end

    send_data "\xEF\xBB\xBF" + csv,
              filename: "代謝錠回購買清纖粉名單_#{start_date}_#{end_date}.csv",
              type: "text/csv; charset=utf-8"
  end

  private

  def parse_date(str)
    Date.iso8601(str.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def query_customers(start_date, end_date)
    sql = <<~SQL
      WITH cohort AS (
        SELECT email, (order_count - 1) AS metabolism_repurchase_count
        FROM customer_series_loyalties
        WHERE series = '代謝錠'
          AND first_date >= #{connection.quote(start_date)}
          AND first_date <= #{connection.quote(end_date)}
      ),
      qingxian_count AS (
        SELECT email, COUNT(DISTINCT order_number) AS qingxian_count
        FROM shopline_orders
        WHERE product_name ILIKE '%清纖粉%' AND payment_status = '已付款' AND email IS NOT NULL
        GROUP BY email
      ),
      order_totals AS (
        SELECT email, COUNT(DISTINCT order_number) AS total_orders, SUM(total_amount) AS total_spend
        FROM shopline_orders
        WHERE payment_status = '已付款' AND email IS NOT NULL
        GROUP BY email
      ),
      ig AS (
        SELECT DISTINCT ON (LOWER(TRIM(email))) LOWER(TRIM(email)) AS email_key, instagram_account
        FROM shopline_orders
        WHERE email IS NOT NULL AND instagram_account IS NOT NULL AND instagram_account <> ''
        ORDER BY LOWER(TRIM(email)), order_date DESC
      )
      SELECT
        COALESCE(sc.full_name, '') AS full_name,
        COALESCE(ig.instagram_account, '') AS instagram_account,
        c.metabolism_repurchase_count,
        q.qingxian_count,
        ot.total_orders,
        ot.total_spend,
        COALESCE(sc.membership_level, '') AS membership_level
      FROM cohort c
      JOIN qingxian_count q ON LOWER(TRIM(q.email)) = LOWER(TRIM(c.email))
      LEFT JOIN order_totals ot ON LOWER(TRIM(ot.email)) = LOWER(TRIM(c.email))
      LEFT JOIN shopline_customers sc ON LOWER(TRIM(sc.email)) = LOWER(TRIM(c.email))
      LEFT JOIN ig ON ig.email_key = LOWER(TRIM(c.email))
      ORDER BY #{MEMBERSHIP_RANK_SQL}, ot.total_spend DESC NULLS LAST
    SQL

    connection.select_all(sql).to_a
  end

  def connection
    ActiveRecord::Base.connection
  end
end

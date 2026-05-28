class SubscriptionStrategyController < ApplicationController
  def index
    @combo_data = Rails.cache.fetch("subscription_strategy:combo:v1", expires_in: 2.hours) do
      build_combo_data
    end
  end

  private

  def build_combo_data
    # 每人購買系列數分佈
    series_count_dist = ActiveRecord::Base.connection.execute(<<~SQL).to_a
      WITH csc AS (
        SELECT email, COUNT(DISTINCT series) AS n
        FROM customer_series_loyalties
        GROUP BY email
      )
      SELECT n, COUNT(*) AS customer_count
      FROM csc
      GROUP BY n
      ORDER BY n
    SQL

    total_customers = series_count_dist.sum { |r| r["customer_count"].to_i }

    # Top 熱門兩兩搭配
    top_pairs = ActiveRecord::Base.connection.execute(<<~SQL).to_a
      WITH customer_series AS (
        SELECT email, array_agg(DISTINCT series ORDER BY series) AS series_list
        FROM customer_series_loyalties
        GROUP BY email
        HAVING COUNT(DISTINCT series) >= 2
      ),
      pairs AS (
        SELECT series_list[i] AS s1, series_list[j] AS s2
        FROM customer_series,
          generate_subscripts(series_list, 1) i,
          generate_subscripts(series_list, 1) j
        WHERE i < j
      )
      SELECT s1, s2, COUNT(*) AS pair_count
      FROM pairs
      GROUP BY s1, s2
      ORDER BY pair_count DESC
      LIMIT 15
    SQL

    # 各系列每筆訂單購買瓶數分佈
    qty_raw = ActiveRecord::Base.connection.execute(<<~SQL).to_a
      SELECT
        CASE
          WHEN product_name LIKE '%代謝%'   THEN '代謝錠'
          WHEN product_name LIKE '%薑黃%'   THEN '薑黃'
          WHEN product_name LIKE '%全能%'   THEN '全能'
          WHEN product_name LIKE '%穀胱甘肽%' THEN '穀胱甘肽'
          WHEN product_name LIKE '%美白%'   THEN '美白'
          WHEN product_name LIKE '%膠原%'   THEN '膠原蛋白'
        END AS series,
        quantity,
        COUNT(*) AS order_count
      FROM shopline_orders
      WHERE payment_status = '已付款'
        AND (
          product_name LIKE '%代謝%' OR product_name LIKE '%薑黃%' OR
          product_name LIKE '%全能%' OR product_name LIKE '%穀胱甘肽%' OR
          product_name LIKE '%美白%' OR product_name LIKE '%膠原%'
        )
        AND quantity IS NOT NULL AND quantity > 0
      GROUP BY series, quantity
      ORDER BY series, quantity
    SQL

    # 整理成 { series => { qty => count } }，只保留 1~6瓶，6以上合併
    qty_by_series = {}
    qty_raw.each do |row|
      s = row["series"]; next unless s
      q = row["quantity"].to_i
      c = row["order_count"].to_i
      qty_by_series[s] ||= Hash.new(0)
      bucket = q <= 6 ? q : 99
      qty_by_series[s][bucket] += c
    end

    {
      series_count_dist: series_count_dist,
      total_customers:   total_customers,
      top_pairs:         top_pairs,
      qty_by_series:     qty_by_series
    }
  end
end

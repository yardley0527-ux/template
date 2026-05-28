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

    {
      series_count_dist: series_count_dist,
      total_customers:   total_customers,
      top_pairs:         top_pairs
    }
  end
end

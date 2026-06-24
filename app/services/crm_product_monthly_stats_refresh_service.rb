# frozen_string_literal: true

# Rollup Phase 2C-1 (MVP) — rebuilds crm_product_monthly_stats for one
# product_key + stat_month, aggregating ShoplineOrder line items directly.
#
# CRM notification metrics are intentionally left as 0 in Phase 2C-1 because
# OmnipotentNotificationStatus is empty in current data verification.
class CrmProductMonthlyStatsRefreshService
  LOCK_NAMESPACE = "crm_product_monthly_stats_refresh"

  def self.call(product_key:, stat_month: Date.current.beginning_of_month)
    new(product_key: product_key, stat_month: stat_month).call
  end

  def initialize(product_key:, stat_month:)
    @product_key = product_key
    @stat_month  = stat_month.beginning_of_month
    @product     = JourneyProducts::PRODUCTS.fetch(product_key) do
      raise ArgumentError, "Unknown product_key: #{product_key.inspect}"
    end
  end

  def call
    with_lock do
      metrics = fetch_metrics
      upsert_metrics(metrics)
      metrics
    end
  end

  private

  # ── Advisory lock ─────────────────────────────────────────────────
  # Scope: product_key + stat_month — a different stat_month for the same
  # product_key does not contend for the same lock.

  def with_lock
    conn = ActiveRecord::Base.connection
    lock_name = conn.quote("#{LOCK_NAMESPACE}:#{@product_key}:#{@stat_month}")

    acquired = ActiveModel::Type::Boolean.new.cast(
      conn.select_value("SELECT pg_try_advisory_lock(hashtext(#{lock_name}))")
    )

    unless acquired
      Rails.logger.info(
        "[CrmProductMonthlyStatsRefreshService] lock busy, skipping product_key=#{@product_key} stat_month=#{@stat_month}"
      )
      return :skipped
    end

    begin
      yield
    ensure
      conn.execute("SELECT pg_advisory_unlock(hashtext(#{lock_name}))")
    end
  end

  # ── Aggregation ───────────────────────────────────────────────────
  # new_buyers_count and natural_revenue both come from a single scan of
  # shopline_orders, filtered to this month + this product's SQL pattern.
  #
  # natural_revenue sums checkout_amount per matching LINE ITEM — not the
  # whole order's total_amount. A single order can contain line items for
  # several tracked products; summing whole-order totals once per matching
  # product_key would multiply-count that order's revenue across products.
  # Line-item summation avoids that without needing an order_number dedup
  # step at all.

  def fetch_metrics
    conn = ActiveRecord::Base.connection
    month_start = conn.quote(@stat_month)
    month_end   = conn.quote(@stat_month.end_of_month)

    sql = <<~SQL
      SELECT
        COUNT(DISTINCT NULLIF(email, '')) AS new_buyers_count,
        COALESCE(SUM(COALESCE(checkout_amount, 0)), 0) AS natural_revenue
      FROM shopline_orders
      WHERE (#{@product[:sql]})
        AND order_date >= #{month_start}
        AND order_date <= #{month_end}
    SQL

    row = conn.select_one(sql)
    {
      new_buyers_count: row["new_buyers_count"].to_i,
      natural_revenue:  row["natural_revenue"].to_d
    }
  end

  # ── Persistence ───────────────────────────────────────────────────
  # notified_count / replied_count / ordered_count / crm_attributed_revenue
  # are hardcoded to 0 — see file header.

  def upsert_metrics(metrics)
    conn = ActiveRecord::Base.connection
    now  = conn.quote(Time.current)

    conn.execute(<<~SQL)
      INSERT INTO crm_product_monthly_stats (
        product_key, stat_month,
        new_buyers_count, notified_count, replied_count, ordered_count,
        natural_revenue, crm_attributed_revenue,
        refreshed_at, created_at, updated_at
      )
      VALUES (
        #{conn.quote(@product_key)}, #{conn.quote(@stat_month)},
        #{metrics[:new_buyers_count]}, 0, 0, 0,
        #{conn.quote(metrics[:natural_revenue])}, 0.00,
        #{now}, #{now}, #{now}
      )
      ON CONFLICT (product_key, stat_month) DO UPDATE SET
        new_buyers_count       = EXCLUDED.new_buyers_count,
        notified_count          = EXCLUDED.notified_count,
        replied_count           = EXCLUDED.replied_count,
        ordered_count           = EXCLUDED.ordered_count,
        natural_revenue         = EXCLUDED.natural_revenue,
        crm_attributed_revenue  = EXCLUDED.crm_attributed_revenue,
        refreshed_at            = EXCLUDED.refreshed_at,
        updated_at              = NOW()
    SQL
  end
end

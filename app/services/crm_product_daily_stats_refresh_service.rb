# frozen_string_literal: true

# Rollup Phase 2B — rebuilds crm_product_daily_stats for one product_key + stat_date,
# aggregating from crm_customer_product_trackings (Phase 2A's output table).
class CrmProductDailyStatsRefreshService
  OVERDUE_FLOOR_DAYS = -60
  LOCK_NAMESPACE      = "crm_product_daily_stats_refresh"

  def self.call(product_key:, stat_date: Date.current)
    new(product_key: product_key, stat_date: stat_date).call
  end

  def initialize(product_key:, stat_date:)
    @product_key = product_key
    @stat_date   = stat_date
  end

  def call
    with_lock do
      counts = fetch_counts
      upsert_counts(counts)
      counts
    end
  end

  private

  # ── Advisory lock ─────────────────────────────────────────────────
  # Scope: product_key + stat_date — a different stat_date for the same
  # product_key does not contend for the same lock.

  def with_lock
    conn = ActiveRecord::Base.connection
    lock_name = conn.quote("#{LOCK_NAMESPACE}:#{@product_key}:#{@stat_date}")

    acquired = ActiveModel::Type::Boolean.new.cast(
      conn.select_value("SELECT pg_try_advisory_lock(hashtext(#{lock_name}))")
    )

    unless acquired
      Rails.logger.info(
        "[CrmProductDailyStatsRefreshService] lock busy, skipping product_key=#{@product_key} stat_date=#{@stat_date}"
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
  # All 8 segment counts come from a single aggregate query against the
  # tracking table — status segments are derived from
  # (expected_return_date / suggested_reminder_date) - stat_date,
  # customer-type segments from (cross_wave_repeat, total_bottles).

  def fetch_counts
    conn = ActiveRecord::Base.connection
    d = "DATE #{conn.quote(@stat_date)}"

    sql = <<~SQL
      SELECT
        COUNT(*) FILTER (
          WHERE (suggested_reminder_date - #{d}) > 0
        ) AS not_urgent_count,
        COUNT(*) FILTER (
          WHERE (suggested_reminder_date - #{d}) <= 0
            AND (expected_return_date    - #{d}) >= 0
        ) AS remind_now_count,
        COUNT(*) FILTER (
          WHERE (expected_return_date - #{d}) < 0
            AND (expected_return_date - #{d}) >= #{OVERDUE_FLOOR_DAYS}
        ) AS overdue_count,
        COUNT(*) FILTER (
          WHERE (expected_return_date - #{d}) < #{OVERDUE_FLOOR_DAYS}
        ) AS at_risk_count,
        COUNT(*) FILTER (WHERE cross_wave_repeat AND total_bottles >= 6) AS vip_count,
        COUNT(*) FILTER (WHERE NOT cross_wave_repeat AND total_bottles >= 6) AS big_count,
        COUNT(*) FILTER (WHERE total_bottles BETWEEN 3 AND 5) AS small_count,
        COUNT(*) FILTER (WHERE total_bottles < 3) AS single_count
      FROM crm_customer_product_trackings
      WHERE product_key = #{conn.quote(@product_key)}
    SQL

    conn.select_one(sql).transform_values(&:to_i).symbolize_keys
  end

  # ── Persistence ───────────────────────────────────────────────────

  def upsert_counts(counts)
    conn = ActiveRecord::Base.connection
    now  = conn.quote(Time.current)

    conn.execute(<<~SQL)
      INSERT INTO crm_product_daily_stats (
        product_key, stat_date,
        not_urgent_count, remind_now_count, overdue_count, at_risk_count,
        vip_count, big_count, small_count, single_count,
        refreshed_at, created_at, updated_at
      )
      VALUES (
        #{conn.quote(@product_key)}, #{conn.quote(@stat_date)},
        #{counts[:not_urgent_count]}, #{counts[:remind_now_count]},
        #{counts[:overdue_count]}, #{counts[:at_risk_count]},
        #{counts[:vip_count]}, #{counts[:big_count]},
        #{counts[:small_count]}, #{counts[:single_count]},
        #{now}, #{now}, #{now}
      )
      ON CONFLICT (product_key, stat_date) DO UPDATE SET
        not_urgent_count = EXCLUDED.not_urgent_count,
        remind_now_count = EXCLUDED.remind_now_count,
        overdue_count    = EXCLUDED.overdue_count,
        at_risk_count    = EXCLUDED.at_risk_count,
        vip_count        = EXCLUDED.vip_count,
        big_count        = EXCLUDED.big_count,
        small_count      = EXCLUDED.small_count,
        single_count     = EXCLUDED.single_count,
        refreshed_at     = EXCLUDED.refreshed_at,
        updated_at       = NOW()
    SQL
  end
end

# frozen_string_literal: true

# Rebuilds crm_customer_product_trackings for a single product_key.
#
# Data sources: ShoplineOrder (eligibility / last order / order_count / total_bottles),
# ShoplineCustomer (existence filter only). OmnipotentNotificationStatus is intentionally
# not used here.
class CrmCustomerProductTrackingRefreshService
  REMINDER_BUFFER_DAYS  = 7
  ELIGIBILITY_WINDOW_DAYS = 365

  def self.call(product_key:)
    new(product_key: product_key).call
  end

  def initialize(product_key:)
    @product_key = product_key
    @product     = JourneyProducts::PRODUCTS.fetch(product_key)
  end

  def call
    lock_key = advisory_lock_key
    unless try_advisory_lock(lock_key)
      Rails.logger.info("[CrmCustomerProductTrackingRefreshService] skip product_key=#{@product_key} (lock held by another process)")
      return false
    end

    begin
      refresh_started_at = Time.current

      last_order_by_email = fetch_last_orders_within_window
      return true if last_order_by_email.empty?

      valid_emails = filter_existing_customers(last_order_by_email.keys)
      return true if valid_emails.empty?

      order_counts   = fetch_order_counts(valid_emails)
      bottle_totals  = fetch_total_bottles(valid_emails)

      rows = build_rows(valid_emails, last_order_by_email, order_counts, bottle_totals, refresh_started_at)

      upsert_rows(rows)
      purge_stale_rows(refresh_started_at)

      true
    ensure
      release_advisory_lock(lock_key)
    end
  end

  private

  # ── Step 3: eligibility + last order (365-day window) ──────────────

  def fetch_last_orders_within_window
    since_date = Date.today - ELIGIBILITY_WINDOW_DAYS

    orders_raw = ShoplineOrder
      .where(@product[:sql])
      .where("order_date >= ?", since_date.beginning_of_day)
      .where.not(email: [nil, ""])
      .order(:email, order_date: :desc)
      .pluck(:email, :product_name, :order_date)

    last_order_by_email = {}
    orders_raw.each do |email, product_name, order_date|
      last_order_by_email[email] ||= { product_name: product_name, order_date: order_date.to_date }
    end
    last_order_by_email
  end

  # ── Step 4: ShoplineCustomer existence filter ───────────────────────

  def filter_existing_customers(emails)
    ShoplineCustomer.where(email: emails).pluck(:email)
  end

  # ── Step 5: order_count (full history, no date filter) ──────────────

  def fetch_order_counts(emails)
    ShoplineOrder.where(@product[:sql]).where(email: emails).group(:email).count
  end

  # ── Step 6: total_bottles (full history, no date filter) ───────────

  def fetch_total_bottles(emails)
    totals = Hash.new(0)
    ShoplineOrder.where(@product[:sql]).where(email: emails).pluck(:email, :product_name).each do |email, product_name|
      totals[email] += extract_bottles(product_name)
    end
    totals
  end

  # ── Step 7-8: derived fields + upsert payload ───────────────────────

  def build_rows(emails, last_order_by_email, order_counts, bottle_totals, refreshed_at)
    emails.map do |email|
      order   = last_order_by_email[email]
      bought  = order[:order_date]
      bottles = extract_bottles(order[:product_name])

      expected_return_date    = bought + expected_days(bottles)
      suggested_reminder_date = expected_return_date - REMINDER_BUFFER_DAYS

      {
        email:                    email,
        product_key:              @product_key,
        last_order_date:          bought,
        last_order_product_name:  order[:product_name],
        last_order_bottles:       bottles,
        expected_return_date:     expected_return_date,
        suggested_reminder_date:  suggested_reminder_date,
        order_count:              order_counts[email]  || 0,
        total_bottles:            bottle_totals[email] || 0,
        refreshed_at:             refreshed_at,
        updated_at:               refreshed_at
      }
    end
  end

  # ── Step 9: batch upsert (raw SQL — no AR model exists for this table) ──

  def upsert_rows(rows)
    return if rows.empty?

    conn = ActiveRecord::Base.connection
    now  = conn.quote(Time.current)

    values_sql = rows.map do |row|
      "(" + [
        conn.quote(row[:email]),
        conn.quote(row[:product_key]),
        conn.quote(row[:last_order_date]),
        conn.quote(row[:last_order_product_name]),
        conn.quote(row[:last_order_bottles]),
        conn.quote(row[:expected_return_date]),
        conn.quote(row[:suggested_reminder_date]),
        conn.quote(row[:order_count]),
        conn.quote(row[:total_bottles]),
        conn.quote(row[:refreshed_at]),
        now,
        now
      ].join(", ") + ")"
    end.join(",\n")

    sql = <<~SQL
      INSERT INTO crm_customer_product_trackings (
        email, product_key, last_order_date, last_order_product_name, last_order_bottles,
        expected_return_date, suggested_reminder_date, order_count, total_bottles,
        refreshed_at, created_at, updated_at
      )
      VALUES
        #{values_sql}
      ON CONFLICT (email, product_key) DO UPDATE SET
        last_order_date          = EXCLUDED.last_order_date,
        last_order_product_name  = EXCLUDED.last_order_product_name,
        last_order_bottles       = EXCLUDED.last_order_bottles,
        expected_return_date     = EXCLUDED.expected_return_date,
        suggested_reminder_date  = EXCLUDED.suggested_reminder_date,
        order_count              = EXCLUDED.order_count,
        total_bottles            = EXCLUDED.total_bottles,
        refreshed_at             = EXCLUDED.refreshed_at,
        updated_at               = EXCLUDED.updated_at
    SQL

    conn.execute(sql)
  end

  # ── Step 10: stale purge, strictly scoped to this product_key ──────

  def purge_stale_rows(refresh_started_at)
    conn = ActiveRecord::Base.connection
    sql  = <<~SQL
      DELETE FROM crm_customer_product_trackings
      WHERE product_key = #{conn.quote(@product_key)}
        AND refreshed_at < #{conn.quote(refresh_started_at)}
    SQL
    conn.execute(sql)
  end

  # ── Advisory lock (Phase 1 concurrency control) ─────────────────────

  def advisory_lock_key
    Zlib.crc32("crm_customer_product_tracking_refresh:#{@product_key}")
  end

  def try_advisory_lock(key)
    result = ActiveRecord::Base.connection.select_value("SELECT pg_try_advisory_lock(#{key})")
    ActiveRecord::Type::Boolean.new.cast(result)
  end

  def release_advisory_lock(key)
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(#{key})")
  end

  # ── Bottle extraction / expected-days helpers ───────────────────────
  # Mirrors OmnipotentRestockController#extract_bottles and #expected_days exactly.

  # TODO: replace with BottleExtractor after Task 8 resumes
  def extract_bottles(product_name)
    return 1 if product_name.nil?
    m    = product_name.match(@product[:regex])
    base = if m
      m[1].to_i
    elsif (m2 = product_name.match(/[（(](\d+)[瓶盒]/))
      m2[1].to_i
    else
      1
    end
    base + (product_name.match(/送(\d+)/)&.[](1).to_i || 0)
  end

  def expected_days(bottles)
    medians = @product[:medians]
    return medians[bottles] if medians.key?(bottles)
    keys = medians.keys.sort
    lo = keys.select { |k| k < bottles }.last
    hi = keys.select { |k| k > bottles }.first
    return medians[lo || hi] unless lo && hi
    lo_v = medians[lo]; hi_v = medians[hi]
    (lo_v + (hi_v - lo_v).to_f * (bottles - lo) / (hi - lo)).round
  end
end

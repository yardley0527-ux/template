# frozen_string_literal: true

# Rollup Phase 2A — rebuilds crm_customer_product_trackings for one product_key.
# Mirrors OmnipotentRestockController#build_restock_data's eligibility/aggregation
# logic so the cached table stays consistent with the live page.
class CrmCustomerProductTrackingRefreshService
  ELIGIBILITY_WINDOW_DAYS = 365
  REMINDER_BUFFER_DAYS    = 7
  LOCK_NAMESPACE          = "crm_customer_product_tracking_refresh"

  def self.call(product_key:)
    new(product_key: product_key).call
  end

  def initialize(product_key:)
    @product_key = product_key
    @product     = JourneyProducts::PRODUCTS.fetch(product_key) do
      raise ArgumentError, "Unknown product_key: #{product_key.inspect}"
    end
  end

  def call
    with_product_lock do
      refresh_started_at = Time.current
      rows = build_rows
      upsert_rows(rows)
      purge_stale(refresh_started_at)
      rows.size
    end
  end

  private

  # ── Advisory lock ─────────────────────────────────────────────────
  # Second concurrent call for the same product_key skips instead of blocking.

  def with_product_lock
    conn = ActiveRecord::Base.connection
    lock_name = conn.quote("#{LOCK_NAMESPACE}:#{@product_key}")

    acquired = ActiveModel::Type::Boolean.new.cast(
      conn.select_value("SELECT pg_try_advisory_lock(hashtext(#{lock_name}))")
    )

    unless acquired
      Rails.logger.info(
        "[CrmCustomerProductTrackingRefreshService] lock busy, skipping product_key=#{@product_key}"
      )
      return :skipped
    end

    begin
      yield
    ensure
      conn.execute("SELECT pg_advisory_unlock(hashtext(#{lock_name}))")
    end
  end

  # ── Row building ──────────────────────────────────────────────────

  def build_rows
    last_order_by_email = fetch_last_orders_within_window
    return [] if last_order_by_email.empty?

    valid_emails = fetch_valid_emails(last_order_by_email.keys)
    return [] if valid_emails.empty?

    order_counts  = fetch_order_counts(valid_emails)
    bottle_totals = fetch_bottle_totals(valid_emails)
    now = Time.current

    valid_emails.map do |email|
      order = last_order_by_email[email]
      next unless order

      bottles                 = extract_bottles(order[:product_name])
      expected_return_date    = order[:order_date] + expected_days(bottles)
      suggested_reminder_date = expected_return_date - REMINDER_BUFFER_DAYS

      {
        email:                   email,
        product_key:             @product_key,
        last_order_date:         order[:order_date],
        last_order_product_name: order[:product_name],
        last_order_bottles:      bottles,
        expected_return_date:    expected_return_date,
        suggested_reminder_date: suggested_reminder_date,
        order_count:             order_counts[email] || 0,
        total_bottles:           bottle_totals[email] || 0,
        refreshed_at:            now
      }
    end.compact
  end

  # eligibility / last_order_date: last 365 days only, matching product SQL.
  def fetch_last_orders_within_window
    since_date = Date.current - ELIGIBILITY_WINDOW_DAYS

    last_order_by_email = {}
    ShoplineOrder
      .where(@product[:sql])
      .where("order_date >= ?", since_date.beginning_of_day)
      .where.not(email: [nil, ""])
      .order(:email, order_date: :desc)
      .pluck(:email, :product_name, :order_date)
      .each do |email, product_name, order_date|
        last_order_by_email[email] ||= { product_name: product_name, order_date: order_date.to_date }
      end
    last_order_by_email
  end

  # ShoplineCustomer check is existence-only — no attributes are read.
  def fetch_valid_emails(candidate_emails)
    ShoplineCustomer.where(email: candidate_emails).distinct.pluck(:email)
  end

  # order_count: product SQL + valid_emails, full period (no 365-day bound).
  def fetch_order_counts(valid_emails)
    ShoplineOrder.where(@product[:sql]).where(email: valid_emails).group(:email).count
  end

  # total_bottles: product SQL + valid_emails, full period (no 365-day bound).
  def fetch_bottle_totals(valid_emails)
    bottle_totals = Hash.new(0)
    ShoplineOrder.where(@product[:sql]).where(email: valid_emails)
      .pluck(:email, :product_name)
      .each { |email, product_name| bottle_totals[email] += extract_bottles(product_name) }
    bottle_totals
  end

  # ── Persistence ───────────────────────────────────────────────────

  def upsert_rows(rows)
    return if rows.empty?

    conn = ActiveRecord::Base.connection
    values_sql = rows.map { |row| row_values_sql(row) }.join(",\n")

    conn.execute(<<~SQL)
      INSERT INTO crm_customer_product_trackings (
        email, product_key, last_order_date, last_order_product_name,
        last_order_bottles, expected_return_date, suggested_reminder_date,
        order_count, total_bottles, refreshed_at, created_at, updated_at
      )
      VALUES
        #{values_sql}
      ON CONFLICT (email, product_key) DO UPDATE SET
        last_order_date         = EXCLUDED.last_order_date,
        last_order_product_name = EXCLUDED.last_order_product_name,
        last_order_bottles      = EXCLUDED.last_order_bottles,
        expected_return_date    = EXCLUDED.expected_return_date,
        suggested_reminder_date = EXCLUDED.suggested_reminder_date,
        order_count              = EXCLUDED.order_count,
        total_bottles            = EXCLUDED.total_bottles,
        refreshed_at             = EXCLUDED.refreshed_at,
        updated_at               = NOW()
    SQL
  end

  def row_values_sql(row)
    conn = ActiveRecord::Base.connection
    now  = conn.quote(Time.current)

    values = [
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
    ]
    "(#{values.join(', ')})"
  end

  # Stale purge is scoped to this product_key only — never touches other products' rows.
  def purge_stale(refresh_started_at)
    conn = ActiveRecord::Base.connection
    conn.execute(<<~SQL)
      DELETE FROM crm_customer_product_trackings
      WHERE product_key = #{conn.quote(@product_key)}
        AND refreshed_at < #{conn.quote(refresh_started_at)}
    SQL
  end

  # ── Helpers (mirrors OmnipotentRestockController) ────────────────

  # TODO: replace with BottleExtractor after Task 8 resumes
  def extract_bottles(product_name)
    return 1 if product_name.nil?
    m = product_name.match(@product[:regex])
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

    lo_v = medians[lo]
    hi_v = medians[hi]
    (lo_v + (hi_v - lo_v).to_f * (bottles - lo) / (hi - lo)).round
  end
end

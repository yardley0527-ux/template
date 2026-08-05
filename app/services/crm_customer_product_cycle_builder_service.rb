# frozen_string_literal: true

# Rollup：把一個產品的每一次有效購買（ShoplineOrder.valid_paid，已排除退款/
# 取消/未付款/欄位缺漏）建成一列 CrmCustomerProductCycle，並判斷這個週期的
# 下一筆訂單配對狀態。
#
# 顧客識別用全站 identity_key 定義（手機優先，否則 LOWER(TRIM(email))），
# 跟舊有 OmnipotentRestockController／CrmCustomerProductTrackingRefreshService
# 直接比對 email 的作法不同——這是刻意的（Phase 1 決議：新資料表用
# identity_key，舊頁面先不動）。
#
# 冪等：upsert 唯一鍵 (identity_key, product_key, cycle_started_at)；
# manual_override_* 欄位在 ON CONFLICT 時完全不覆寫；matched_at 只在
# match_status 真的改變時才更新，重複執行不會讓已配對的週期時間戳漂移。
class CrmCustomerProductCycleBuilderService
  LOCK_NAMESPACE        = "crm_customer_product_cycle_builder"
  REMINDER_BUFFER_DAYS  = 7
  ADDON_WINDOW_MIN_DAYS = 3
  ADDON_WINDOW_RATIO    = 0.3
  LOOKBACK_DAYS         = 730

  IDENTITY_JOIN_SQL = <<~SQL.squish.freeze
    LEFT JOIN shopline_customers sc
      ON LOWER(TRIM(sc.email)) = LOWER(TRIM(shopline_orders.email))
      AND sc.mobile_phone IS NOT NULL
      AND TRIM(sc.mobile_phone) <> ''
  SQL

  def self.call(product_key:)
    new(product_key: product_key).call
  end

  def initialize(product_key:)
    @product_key = product_key
    @crm_product = CrmProduct.find_by(key: product_key, status: "confirmed")
    @product_matchers = load_product_matchers
    @medians = CrmRepurchaseCycleConfig.medians_for(product_key) # 查一次，避免每個事件都重查（N+1）
  end

  def call
    return :unknown_product unless @crm_product&.sql_pattern.present?

    with_product_lock do
      purchase_events = fetch_purchase_events
      next 0 if purchase_events.empty?

      identity_keys      = purchase_events.map { |e| e[:identity_key] }.uniq
      subsequent_orders  = fetch_subsequent_orders(identity_keys)

      rows = purchase_events.filter_map { |event| build_cycle_row(event, subsequent_orders[event[:identity_key]] || []) }
      upsert_rows(rows)
      rows.size
    end
  end

  private

  # ── Advisory lock（同 CrmCustomerProductTrackingRefreshService 的模式）──

  def with_product_lock
    conn = ActiveRecord::Base.connection
    lock_name = conn.quote("#{LOCK_NAMESPACE}:#{@product_key}")

    acquired = ActiveModel::Type::Boolean.new.cast(
      conn.select_value("SELECT pg_try_advisory_lock(hashtext(#{lock_name}))")
    )

    unless acquired
      Rails.logger.info("[CrmCustomerProductCycleBuilderService] lock busy, skipping product_key=#{@product_key}")
      return :skipped
    end

    begin
      yield
    ensure
      conn.execute("SELECT pg_advisory_unlock(hashtext(#{lock_name}))")
    end
  end

  # ── 產品比對（沿用 crm_products.sql_pattern 語意，'%X%' LIKE 子字串）──

  def load_product_matchers
    CrmProduct.confirmed.pluck(:key, :sql_pattern).each_with_object({}) do |(key, pattern), h|
      h[key] = extract_like_substrings(pattern)
    end
  end

  def extract_like_substrings(sql_pattern)
    return [] if sql_pattern.blank?

    sql_pattern.scan(/LIKE\s+'%([^%]+)%'/i).flatten
  end

  def product_key_for(product_name)
    return nil if product_name.blank?

    @product_matchers.find { |_key, substrings| substrings.any? { |s| product_name.include?(s) } }&.first
  end

  # ── 購買事件：同 identity_key + 同一天的多筆明細合併成一次購買，瓶數加總 ──

  def fetch_purchase_events
    since_date = Date.current - LOOKBACK_DAYS

    rows = ShoplineOrder.valid_paid
      .where(@crm_product.sql_pattern)
      .where("order_date >= ?", since_date.beginning_of_day)
      .joins(IDENTITY_JOIN_SQL)
      .pluck(
        Arel.sql("COALESCE(NULLIF(TRIM(sc.mobile_phone), ''), LOWER(TRIM(shopline_orders.email)))"),
        :email, :product_name, :order_date, :order_number
      )

    grouped = Hash.new { |h, k| h[k] = [] }
    rows.each do |identity_key, email, product_name, order_date, order_number|
      grouped[[identity_key, order_date.to_date]] << { email: email, product_name: product_name, order_number: order_number }
    end

    grouped.map do |(identity_key, date), lines|
      {
        identity_key:         identity_key,
        email:                lines.map { |l| l[:email] }.compact.min,
        cycle_started_at:     date,
        source_order_number:  lines.map { |l| l[:order_number] }.compact.min,
        bottle_count:         lines.sum { |l| BottleExtractor.call(l[:product_name], @product_key) }
      }
    end
  end

  # ── 這些 identity_key 之後（任何產品）的全部有效訂單，供下一筆訂單配對 ──

  # order_date 欄位是 timestamp without time zone，Rails 以 UTC 存入（config.time_zone
  # 是 Taipei，+8）。純 SQL 的 order_date::date 會用 DB session 時區（UTC）取日期，
  # 使跨日界的訂單（例如台北時間當天 00:00–07:59 存成 UTC 前一天）算出錯誤的日期，
  # 進而讓「下一筆訂單」配對錯位一天。這裡先轉回 Taipei 本地時間再取日期，
  # 才會跟 Ruby 端（ActiveRecord 用 Time.zone 讀出的 order_date）一致。
  def fetch_subsequent_orders(identity_keys)
    return {} if identity_keys.empty?

    conn = ActiveRecord::Base.connection
    quoted_keys = identity_keys.map { |k| conn.quote(k) }.join(", ")

    sql = <<~SQL
      SELECT
        COALESCE(NULLIF(TRIM(sc.mobile_phone), ''), LOWER(TRIM(so.email))) AS identity_key,
        so.product_name,
        (so.order_date AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Taipei')::date AS order_date,
        so.order_number
      FROM shopline_orders so
      LEFT JOIN shopline_customers sc
        ON LOWER(TRIM(sc.email)) = LOWER(TRIM(so.email))
        AND sc.mobile_phone IS NOT NULL
        AND TRIM(sc.mobile_phone) <> ''
      WHERE so.payment_status = '已付款'
        AND so.order_number IS NOT NULL AND TRIM(so.order_number) <> ''
        AND so.email IS NOT NULL AND TRIM(so.email) <> ''
        AND so.order_date IS NOT NULL
        AND COALESCE(NULLIF(TRIM(sc.mobile_phone), ''), LOWER(TRIM(so.email))) IN (#{quoted_keys})
    SQL

    result = Hash.new { |h, k| h[k] = [] }
    conn.select_all(sql).each do |row|
      result[row["identity_key"]] << {
        product_name: row["product_name"],
        order_date:   row["order_date"].to_date,
        order_number: row["order_number"]
      }
    end
    result
  end

  # ── 週期列組裝 + 配對分類 ──

  def build_cycle_row(event, identity_orders)
    expected_days = CrmRepurchaseCycleConfig.interpolate(@medians, event[:bottle_count])
    return nil if expected_days.nil? # 無週期設定資料，交由資料品質報告揭露，不硬猜天數

    estimated_finish_date  = event[:cycle_started_at] + expected_days
    suggested_contact_date = estimated_finish_date - REMINDER_BUFFER_DAYS
    match = classify_match(event, identity_orders, expected_days)
    now   = Time.current

    {
      identity_key:               event[:identity_key],
      email:                      event[:email],
      product_key:                @product_key,
      cycle_started_at:           event[:cycle_started_at],
      source_order_number:        event[:source_order_number],
      bottle_count:               event[:bottle_count],
      estimated_usage_days:       expected_days,
      estimated_finish_date:      estimated_finish_date,
      suggested_contact_date:     suggested_contact_date,
      match_status:               match[:status],
      matched_next_order_number:  match[:order_number],
      matched_next_order_date:    match[:order_date],
      matched_next_product_key:   match[:product_key],
      matched_at:                 match[:status] == "not_yet_repurchased" ? nil : now,
      refreshed_at:                now
    }
  end

  # 同品回購 same_product_repurchase / 同品加購 same_product_addon（下一筆同
  # 產品訂單落在「加購觀察窗」內，視為補買而非真正吃完後回購）/ 跨品購買
  # cross_product_purchase（下一筆是別的產品）/ 尚未回購 not_yet_repurchased。
  def classify_match(event, identity_orders, expected_days)
    later = identity_orders.select { |o| o[:order_date] > event[:cycle_started_at] }
    return { status: "not_yet_repurchased", order_number: nil, order_date: nil, product_key: nil } if later.empty?

    earliest_date    = later.map { |o| o[:order_date] }.min
    same_day_orders  = later.select { |o| o[:order_date] == earliest_date }
    same_product_hit = same_day_orders.find { |o| product_key_for(o[:product_name]) == @product_key }

    gap_days     = (earliest_date - event[:cycle_started_at]).to_i
    addon_window = [(expected_days * ADDON_WINDOW_RATIO).round, ADDON_WINDOW_MIN_DAYS].max

    if same_product_hit
      status = gap_days <= addon_window ? "same_product_addon" : "same_product_repurchase"
      { status: status, order_number: same_product_hit[:order_number], order_date: earliest_date, product_key: @product_key }
    else
      representative = same_day_orders.first
      {
        status:      "cross_product_purchase",
        order_number: representative[:order_number],
        order_date:   earliest_date,
        product_key:  product_key_for(representative[:product_name])
      }
    end
  end

  # ── Persistence：manual_override_* 不覆寫，matched_at 只在狀態改變時更新 ──

  def upsert_rows(rows)
    return if rows.empty?

    conn = ActiveRecord::Base.connection
    values_sql = rows.map { |row| row_values_sql(row) }.join(",\n")

    conn.execute(<<~SQL)
      INSERT INTO crm_customer_product_cycles (
        identity_key, email, product_key, cycle_started_at, source_order_number,
        bottle_count, estimated_usage_days, estimated_finish_date, suggested_contact_date,
        match_status, matched_next_order_number, matched_next_order_date, matched_next_product_key,
        matched_at, refreshed_at, created_at, updated_at
      )
      VALUES
        #{values_sql}
      ON CONFLICT (identity_key, product_key, cycle_started_at) DO UPDATE SET
        email                      = EXCLUDED.email,
        source_order_number        = EXCLUDED.source_order_number,
        bottle_count               = EXCLUDED.bottle_count,
        estimated_usage_days       = EXCLUDED.estimated_usage_days,
        estimated_finish_date      = EXCLUDED.estimated_finish_date,
        suggested_contact_date     = EXCLUDED.suggested_contact_date,
        match_status               = EXCLUDED.match_status,
        matched_next_order_number  = EXCLUDED.matched_next_order_number,
        matched_next_order_date    = EXCLUDED.matched_next_order_date,
        matched_next_product_key   = EXCLUDED.matched_next_product_key,
        matched_at = CASE
          WHEN crm_customer_product_cycles.match_status = EXCLUDED.match_status
          THEN crm_customer_product_cycles.matched_at
          ELSE EXCLUDED.matched_at
        END,
        refreshed_at = EXCLUDED.refreshed_at,
        updated_at   = NOW()
    SQL
  end

  def row_values_sql(row)
    conn = ActiveRecord::Base.connection
    now  = conn.quote(Time.current)

    values = [
      conn.quote(row[:identity_key]),
      conn.quote(row[:email]),
      conn.quote(row[:product_key]),
      conn.quote(row[:cycle_started_at]),
      conn.quote(row[:source_order_number]),
      conn.quote(row[:bottle_count]),
      conn.quote(row[:estimated_usage_days]),
      conn.quote(row[:estimated_finish_date]),
      conn.quote(row[:suggested_contact_date]),
      conn.quote(row[:match_status]),
      conn.quote(row[:matched_next_order_number]),
      conn.quote(row[:matched_next_order_date]),
      conn.quote(row[:matched_next_product_key]),
      conn.quote(row[:matched_at]),
      conn.quote(row[:refreshed_at]),
      now,
      now
    ]
    "(#{values.join(', ')})"
  end
end

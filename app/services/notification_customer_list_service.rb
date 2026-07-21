# frozen_string_literal: true

# Expands an aggregate notification card into its underlying customer list.
# Always re-derives the candidate set from metadata["query"] (never from the
# capped sample_shopline_customer_ids) and live-rechecks every candidate
# against raw shopline_orders — not the nightly-refreshed cache tables the
# generating rule used — so a customer who has already repurchased since the
# last rollup never shows up as still owed a reminder.
class NotificationCustomerListService
  RESULT_LIMIT = 200

  def self.call(notification)
    new(notification).call
  end

  def initialize(notification)
    @notification = notification
    @query = notification.metadata["query"] || {}
  end

  def call
    case notification.category
    when "customer_runout", "customer_overdue" then product_tracking_rows
    when "high_spender_no_second"                then high_spender_rows
    when "vip_silent"                            then vip_silent_rows
    else []
    end
  end

  private

  attr_reader :notification, :query

  def product_tracking_rows
    product_key = query["product_key"]
    return [] if product_key.blank?

    scope = CrmCustomerProductTracking.where(product_key: product_key)
    scope =
      if query["expected_return_date_from"]
        scope.where(expected_return_date: query["expected_return_date_from"]..query["expected_return_date_to"])
      elsif query["overdue_days_from"]
        today = Date.current
        scope.where(expected_return_date: (today - query["overdue_days_to"].to_i)..(today - query["overdue_days_from"].to_i))
      else
        scope.none
      end

    sql_pattern = tracking_sql_pattern(product_key)
    rows = scope.order(:expected_return_date).limit(RESULT_LIMIT).to_a
    customers = customers_by_email(rows.map(&:email))

    rows.filter_map do |row|
      next if repurchased_since?(email: row.email, sql_pattern: sql_pattern, since: row.last_order_date)

      row_hash(email: row.email, customer: customers[row.email], last_order_date: row.last_order_date,
               expected_return_date: row.expected_return_date)
    end
  end

  def high_spender_rows
    month = query["first_month"]
    return [] if month.blank?

    from_date = Date.parse("#{month}-01").beginning_of_month
    to_date = from_date.end_of_month
    series = query["first_series"]

    scope = CustomerPurchaseSummary
            .where(first_date: from_date.beginning_of_day..to_date.end_of_day)
            .where("first_amount >= ?", query["first_amount_gte"] || 0)
    # "未分類" is a display fallback (COALESCE(NULLIF(first_series,''), '未分類')) —
    # no row's first_series column literally holds that string, so it must map
    # back to null-or-blank rather than an equality filter.
    scope = series == "未分類" ? scope.where(first_series: [nil, ""]) : scope.where(first_series: series)

    summaries = scope.order(first_date: :asc).limit(RESULT_LIMIT).to_a
    customers = customers_by_email(summaries.map(&:email))

    summaries.filter_map do |summary|
      next if genuine_second_purchase_exists?(summary.email, since: summary.first_date)

      row_hash(email: summary.email, customer: customers[summary.email],
               first_date: summary.first_date&.to_date, first_amount: summary.first_amount.to_i)
    end
  end

  def vip_silent_rows
    from_days = query["silent_days_from"]
    return [] if from_days.nil?

    levels = Array(query["membership_level_in"])
    to_days = query["silent_days_to"]
    quoted_levels = levels.map { |l| ActiveRecord::Base.connection.quote(l) }.join(",")

    sql = <<~SQL
      SELECT sc.id AS customer_id, sc.email, sc.membership_level, cps.last_order_date
      FROM shopline_customers sc
      JOIN customer_purchase_summaries cps
        ON cps.identity_key = COALESCE(NULLIF(TRIM(sc.mobile_phone), ''), LOWER(TRIM(sc.email)))
      WHERE sc.membership_level IN (#{quoted_levels})
        AND (CURRENT_DATE - cps.last_order_date::date) >= #{from_days.to_i}
        #{to_days.present? ? "AND (CURRENT_DATE - cps.last_order_date::date) <= #{to_days.to_i}" : ""}
      ORDER BY cps.last_order_date ASC
      LIMIT #{RESULT_LIMIT}
    SQL

    result_rows = ActiveRecord::Base.connection.select_all(sql).to_a
    customers = customers_by_email(result_rows.map { |r| r["email"] })

    result_rows.filter_map do |r|
      last_order_date = r["last_order_date"]&.to_date
      next if repurchased_since?(email: r["email"], sql_pattern: nil, since: last_order_date)

      row_hash(email: r["email"], customer: customers[r["email"]],
               last_order_date: last_order_date, membership_level: r["membership_level"])
    end
  end

  def tracking_sql_pattern(product_key)
    crm_product = NotificationRules::ProductKeyMapping.crm_product_for(product_key)
    return nil unless crm_product

    crm_product.sql_pattern.presence || "product_name LIKE '%#{crm_product.label}%'"
  end

  # 真正即時檢查：不依賴任何每日快取表，直接查 shopline_orders 是否已有更新的訂單。
  def repurchased_since?(email:, sql_pattern:, since:)
    return false if email.blank? || since.blank?

    scope = ShoplineOrder.where(email: email).where("order_date > ?", since)
    scope = scope.where(sql_pattern) if sql_pattern.present?
    scope.exists?
  end

  def genuine_second_purchase_exists?(email, since:)
    return false if email.blank? || since.blank?

    ShoplineOrder.where(email: email).where("order_date >= ?", since + 7.days).exists?
  end

  # 一次撈整批 email 對應的客戶資料，避免每一列各自查一次（N+1）。
  def customers_by_email(emails)
    ShoplineCustomer.where(email: emails.compact.uniq).index_by(&:email)
  end

  def row_hash(email:, customer:, **extra)
    {
      customer_id: customer&.id, full_name: customer&.full_name,
      membership_level: customer&.membership_level, mobile_phone: customer&.mobile_phone,
      instagram_account: customer&.instagram_account, email: email
    }.merge(extra)
  end
end

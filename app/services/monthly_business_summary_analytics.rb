# frozen_string_literal: true

class MonthlyBusinessSummaryAnalytics
  OrderRow = Struct.new(:order_number, :email, :order_date, :order_total, :net_amount, keyword_init: true) do
    def month
      order_date.strftime("%Y-%m")
    end
  end

  def self.available_years
    ShoplineOrder.where(payment_status: "已付款")
      .where.not(order_date: nil)
      .distinct
      .pluck(Arel.sql("EXTRACT(YEAR FROM order_date)::int"))
      .sort
  end

  def initialize(year)
    @year  = year.to_i
    @range = Date.new(@year, 1, 1)...Date.new(@year + 1, 1, 1)
  end

  def overview_rows
    months.map do |month, rows|
      per_customer  = rows.group_by(&:email)
      total_customers = per_customer.keys.compact.size
      old_count = per_customer.keys.count { |e| old_customer?(e, month) }
      net = rows.sum(&:net_amount)

      {
        month:              month,
        net_amount:         net,
        paid_order_count:   rows.map(&:order_number).uniq.size,
        total_customers:    total_customers,
        avg_order_amount:   safe_div(net, total_customers),
        repurchase_rate:    safe_div(old_count, total_customers, as_percent: true),
        new_member_count:   new_member_counts[month].to_i
      }
    end
  end

  def breakdown_rows
    months.map do |month, rows|
      per_customer = rows.group_by(&:email)

      new_emails, old_emails = per_customer.keys.compact.partition { |e| new_customer?(e, month) }

      new_revenue = new_emails.sum { |e| per_customer[e].sum(&:order_total) }
      old_revenue = old_emails.sum { |e| per_customer[e].sum(&:order_total) }

      repeat_new_emails = new_emails.select { |e| per_customer[e].map(&:order_number).uniq.size > 1 }
      repeat_new_revenue = repeat_new_emails.sum do |e|
        orders = per_customer[e].sort_by(&:order_date)
        orders.drop(1).sum(&:order_total)
      end

      {
        month:                 month,
        total_customers:       per_customer.keys.compact.size,
        new_count:             new_emails.size,
        new_revenue:           new_revenue,
        new_avg_amount:        safe_div(new_revenue, new_emails.size),
        old_count:             old_emails.size,
        old_revenue:           old_revenue,
        old_avg_amount:        safe_div(old_revenue, old_emails.size),
        new_old_ratio:         safe_div(new_emails.size, old_emails.size),
        new_repeat_count:      repeat_new_emails.size,
        new_repeat_revenue:    repeat_new_revenue
      }
    end
  end

  private

  def months
    @months ||= order_rows.group_by(&:month).sort.to_h
  end

  def order_rows
    @order_rows ||= ShoplineOrder
      .where(payment_status: "已付款", order_date: @range)
      .group(:order_number)
      .pluck(
        :order_number,
        Arel.sql("MAX(email) AS email"),
        Arel.sql("MAX(order_date) AS order_date"),
        Arel.sql("#{ShoplineOrder::TOTAL_SQL} AS order_total"),
        Arel.sql("SUM(COALESCE(checkout_amount, 0)) AS net_amount")
      )
      .map do |order_number, email, order_date, order_total, net_amount|
        OrderRow.new(
          order_number: order_number,
          email:        email,
          order_date:   order_date,
          order_total:  order_total.to_f,
          net_amount:   net_amount.to_f
        )
      end
  end

  def first_dates
    @first_dates ||= begin
      emails = order_rows.map(&:email).compact.uniq
      CustomerPurchaseSummary.where(email: emails).pluck(:email, :first_date).to_h
    end
  end

  def new_member_counts
    @new_member_counts ||= ShoplineCustomer
      .where(member_registered_at: @range)
      .group(Arel.sql("TO_CHAR(member_registered_at, 'YYYY-MM')"))
      .count
  end

  def new_customer?(email, month)
    first_month = first_dates[email]&.strftime("%Y-%m")
    first_month == month
  end

  def old_customer?(email, month)
    first_month = first_dates[email]&.strftime("%Y-%m")
    first_month.present? && first_month < month
  end

  def safe_div(numerator, denominator, as_percent: false)
    return nil if denominator.to_f.zero?

    result = numerator.to_f / denominator
    as_percent ? (result * 100).round(1) : result.round(2)
  end
end

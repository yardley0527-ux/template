class DailyOrdersController < ApplicationController
  TIERS = %w[黑卡 金卡 銀卡 白卡 一般會員].freeze
  TOGGLEABLE_FIELDS = %w[follows_chloe_ig invited_to_follow_product_ig].freeze
  PURCHASE_SUMMARY_FIELDS = %w[line_bound].freeze

  ORDER_TOTAL_SQL = <<~SQL.squish.freeze
    CASE
      WHEN MAX(NULLIF(o.total_amount, 0)) IS NOT NULL THEN MAX(NULLIF(o.total_amount, 0))
      ELSE SUM(COALESCE(o.checkout_amount, 0))
    END
  SQL

  OrderRow = Struct.new(
    :order_number, :customer_name, :ig_account, :email, :order_total, :order_date,
    :is_new_customer, :membership_level, :products, :health_profile, :health_tags,
    :follows_chloe_ig, :invited_to_follow_product_ig, :shopline_customer_id,
    :line_bound, :total_quantity,
    keyword_init: true
  )

  def index
    @date = parse_date(params[:date]) || Date.yesterday
    @tab = %w[new old].include?(params[:tab]) ? params[:tab] : "new"
    @groups = build_groups(@date)
    @new_count = @groups.first.last.size
    @old_count = @groups.drop(1).sum { |_, rows| rows.size }
  end

  def toggle_customer_flag
    field = params[:field].to_s
    return head :bad_request unless (TOGGLEABLE_FIELDS + PURCHASE_SUMMARY_FIELDS).include?(field)

    customer = ShoplineCustomer.find(params[:customer_id])
    value    = ActiveModel::Type::Boolean.new.cast(params[:value])

    if PURCHASE_SUMMARY_FIELDS.include?(field)
      summary = CustomerPurchaseSummary.find_by(email: customer.email)
      return head :not_found unless summary
      summary.update!(field => value)
    else
      profile = customer.customer_profile || customer.build_customer_profile
      profile.update!(field => value)
    end

    head :ok
  end

  def export
    @date = parse_date(params[:date]) || Date.yesterday
    groups = build_groups(@date)

    csv_data = CSV.generate(encoding: "UTF-8") do |csv|
      csv << ["分類", "訂單號碼", "姓名", "IG", "消費金額", "是否購買過同產品", "健康狀況", "健康標籤", "是否追蹤 Chloe IG", "是否已私訊邀請追蹤產品IG", "綁定 LINE"]
      groups.each do |label, rows|
        rows.each do |row|
          csv << [
            label,
            row.order_number,
            row.customer_name,
            row.ig_account,
            row.order_total.to_i,
            same_product_text(row.products),
            row.health_profile.presence,
            row.health_tags.join("、"),
            row.follows_chloe_ig ? "是" : "否",
            row.invited_to_follow_product_ig ? "是" : "否",
            row.line_bound ? "是" : "否"
          ]
        end
      end
    end

    send_data "\xEF\xBB\xBF" + csv_data,
      filename: "每日訂單報表_#{@date}.csv",
      type: "text/csv; charset=utf-8"
  end

  private

  def product_series(name)
    name.to_s.match(/\A([^\d]+)/)&.captures&.first&.strip.presence || name.to_s
  end

  def build_prior_series_dates(emails, before)
    raw = ShoplineOrder.where(email: emails).where("order_date < ?", before).pluck(:email, :product_name, :order_date)
    result = {}
    raw.each do |email, product_name, order_date|
      key = [email, product_series(product_name)]
      result[key] = order_date if result[key].nil? || order_date < result[key]
    end
    result
  end

  def parse_date(value)
    Date.parse(value) if value.present?
  rescue ArgumentError
    nil
  end

  def same_product_text(products)
    products.map { |p| p[:prior_date] ? "#{p[:name]}：✓ #{p[:prior_date].strftime('%Y/%m/%d')}" : "#{p[:name]}：（首次購買）" }.join("\n")
  end
  helper_method :same_product_text

  def build_groups(date)
    day_start = date.beginning_of_day
    day_end   = date.end_of_day

    raw_orders = ShoplineOrder.from("shopline_orders o")
      .joins("LEFT JOIN shopline_customers sc ON sc.email = o.email")
      .select(
        "o.order_number AS order_num",
        "MAX(o.customer_name) AS cust_name",
        "MAX(COALESCE(sc.instagram_account, o.instagram_account)) AS ig_account",
        "MAX(COALESCE(sc.email, o.email)) AS email_val",
        "MAX(COALESCE(sc.membership_level, o.membership_level)) AS membership_level_col",
        "MAX(o.order_date) AS ord_date",
        "#{ORDER_TOTAL_SQL} AS order_total",
        "ARRAY_AGG(DISTINCT o.product_name) AS product_names_arr",
        "SUM(o.quantity) AS total_quantity"
      )
      .where("o.payment_status = '已付款'")
      .where("o.order_date >= ? AND o.order_date < ?", day_start, day_end)
      .group("o.order_number")
      .order(Arel.sql("MAX(o.order_date) ASC"))
      .to_a

    emails = raw_orders.map(&:email_val).compact.uniq

    prior_emails = ShoplineOrder.where(email: emails).where("order_date < ?", day_start).distinct.pluck(:email).to_set

    prior_series_dates = build_prior_series_dates(emails, day_start)

    customers_by_email = ShoplineCustomer.where(email: emails).includes(:customer_profile).index_by(&:email)
    summaries_by_email = CustomerPurchaseSummary.where(email: emails).index_by(&:email)

    rows = raw_orders.map do |o|
      customer = customers_by_email[o.email_val]
      profile  = customer&.customer_profile
      summary  = summaries_by_email[o.email_val]

      products = Array(o.product_names_arr).compact.map do |name|
        prior_date = prior_series_dates[[o.email_val, product_series(name)]]
        { name: name, prior_date: prior_date }
      end

      OrderRow.new(
        order_number: o.order_num,
        customer_name: o.cust_name,
        ig_account: o.ig_account,
        email: o.email_val,
        order_total: o.order_total,
        order_date: o.ord_date,
        is_new_customer: o.email_val.blank? || !prior_emails.include?(o.email_val),
        membership_level: o.membership_level_col,
        products: products,
        health_profile: profile&.health_profile,
        health_tags: profile&.health_tags || [],
        follows_chloe_ig: profile&.follows_chloe_ig || false,
        invited_to_follow_product_ig: profile&.invited_to_follow_product_ig || false,
        shopline_customer_id: customer&.id,
        line_bound: summary&.line_bound || false,
        total_quantity: o.total_quantity.to_i
      )
    end

    rows = rows.sort_by { |r| -r.order_total.to_f }

    new_rows = rows.select(&:is_new_customer)
    old_rows = rows.reject(&:is_new_customer)

    groups = [["新客", new_rows]]
    TIERS.each do |tier|
      tier_rows = old_rows.select { |r| r.membership_level == tier }.sort_by { |r| -r.total_quantity }
      groups << [tier, tier_rows]
    end
    other = old_rows.reject { |r| TIERS.include?(r.membership_level) }.sort_by { |r| -r.total_quantity }
    groups << ["未分級", other] if other.any?

    groups
  end
end

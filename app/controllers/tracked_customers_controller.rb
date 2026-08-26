# frozen_string_literal: true

# 「營運追蹤名單」——客人頁「客人追蹤備註」卡片把 tracked 打勾的人，集中列表。
# 繼承 CustomersController 是為了直接沿用它的篩選／排序 private helper
# （order_sql／to_number／parse_product），這裡只多一個固定的
# customer_profiles.tracked = true 篩選，預設依卡別排序方便分卡別檢視。
class TrackedCustomersController < CustomersController
  def index
    @q                = params[:q].to_s.strip
    @membership_level = params[:membership_level].to_s.strip
    @min_credits      = to_number(params[:min_credits])
    @sort             = params[:sort].to_s.strip.presence || "membership_asc"
    @brand_ambassador = params[:brand_ambassador].to_s.strip
    @big_first_filter = params[:big_first].to_s.strip
    @product_tag      = params[:product_tag].to_s.strip
    @health_tag       = params[:health_tag].to_s.strip
    @recent_purchase  = params[:recent_purchase].to_s.strip

    @membership_order = %w[黑卡 金卡 銀卡 白卡 一般會員 非會員]
    @membership_levels = ShoplineCustomer.distinct.pluck(:membership_level)
      .map { |l| l.presence || "非會員" }
      .uniq
      .sort_by { |l| @membership_order.index(l) || 99 }

    @product_tag_options = CustomerProfile::SHENGTING_PRODUCT_OPTIONS
    @health_tag_options  = CustomerProfile::HEALTH_TAG_OPTIONS

    @page = params[:page].to_i
    @page = 1 if @page <= 0
    @page = MAX_PAGE if @page > MAX_PAGE

    scope = ShoplineCustomer.includes(:customer_profile)
              .joins(:customer_profile).where(customer_profiles: { tracked: true })

    if @q.present?
      like = "%#{@q}%"
      scope = scope.where(
        "shopline_customers.full_name ILIKE :like OR shopline_customers.email ILIKE :like OR shopline_customers.mobile_phone ILIKE :like OR shopline_customers.phone ILIKE :like OR shopline_customers.instagram_account ILIKE :like",
        like: like
      )
    end

    if @membership_level.present?
      scope = if @membership_level == "非會員"
        scope.where(membership_level: [nil, ""])
      else
        scope.where(membership_level: @membership_level)
      end
    end

    scope = scope.where("current_shopping_credits >= ?", @min_credits) if @min_credits
    scope = scope.where("? = ANY(customer_profiles.shengting_product_tags)", @product_tag) if @product_tag.present?
    scope = scope.where("? = ANY(customer_profiles.health_tags)", @health_tag) if @health_tag.present?
    scope = scope.where(customer_profiles: { brand_ambassador_training: true }) if @brand_ambassador == "1"

    if @big_first_filter == "1"
      scope = scope.joins(
        "INNER JOIN (
          SELECT DISTINCT ON (email) email, total_amount AS first_amount
          FROM shopline_orders
          ORDER BY email, order_date ASC
        ) fo ON fo.email = shopline_customers.email"
      ).where("fo.first_amount >= 10000")
    end

    scope = scope
      .joins("LEFT JOIN (
        SELECT email, MAX(order_date) AS last_order_date
        FROM shopline_orders
        WHERE product_name IS NOT NULL AND product_name != ''
        GROUP BY email
      ) lo ON lo.email = shopline_customers.email")
      .select("shopline_customers.*, lo.last_order_date")

    scope = scope.where("lo.last_order_date >= ?", 3.months.ago) if @recent_purchase == "1"

    scope = scope.reorder(Arel.sql(order_sql(@sort)))

    @total = ShoplineCustomer.from(scope.except(:select, :order), :shopline_customers).count

    if @recent_purchase == "1"
      level_scope = ShoplineCustomer.joins(:customer_profile).where(customer_profiles: { tracked: true })
      level_scope = if @membership_level == "非會員"
        level_scope.where(membership_level: [nil, ""])
      elsif @membership_level.present?
        level_scope.where(membership_level: @membership_level)
      else
        level_scope
      end
      @recent_purchase_denominator = level_scope.count
    end

    @total_pages = (@total.to_f / PER_PAGE).ceil
    @total_pages = 1 if @total_pages <= 0
    offset = (@page - 1) * PER_PAGE
    @customers = scope.offset(offset).limit(PER_PAGE)

    emails = @customers.map(&:email).compact.uniq

    all_orders_by_email = ShoplineOrder
      .where(email: emails)
      .where.not(product_name: [nil, ""])
      .select(:email, :product_name, :quantity, :order_date)
      .group_by(&:email)

    @top_products = {}
    @inactive_info = {}
    @last_purchase_products = {}
    all_orders_by_email.each do |email, orders|
      series_counts = Hash.new { |h, k| h[k] = { qty: 0, count: 0 } }
      orders.each do |o|
        series, bottles_per_unit = parse_product(o.product_name)
        series_counts[series][:qty]   += o.quantity.to_i * bottles_per_unit
        series_counts[series][:count] += 1
      end
      @top_products[email] = series_counts.max_by { |_, v| [v[:qty], v[:count]] }&.first

      last_order = orders.max_by(&:order_date)
      if last_order&.order_date
        last_date = last_order.order_date
        last_series = orders.select { |o| o.order_date == last_date }
                             .map { |o| parse_product(o.product_name).first }
                             .uniq
        @last_purchase_products[email] = last_series

        days_ago = (Date.today - last_date.to_date).to_i
        @inactive_info[email] = { days: days_ago, last_product: last_series.first } if days_ago >= 60
      end
    end

    first_orders_by_email = ShoplineOrder
      .where(email: emails)
      .select("DISTINCT ON (email) email, order_date, total_amount")
      .order("email, order_date ASC")
      .index_by(&:email)

    @big_first_orders = {}
    first_orders_by_email.each do |email, order|
      @big_first_orders[email] = order.order_date if order.total_amount.to_f >= 10_000
    end
  end

  private

  # 分卡別列名單：預設依卡別（黑金銀白一般）排序，同卡別內再依累積消費排序；
  # 其餘排序鍵沿用 CustomersController#order_sql。
  def order_sql(sort)
    return <<~SQL.squish if sort == "membership_asc"
      CASE membership_level
        WHEN '黑卡' THEN 1 WHEN '金卡' THEN 2 WHEN '銀卡' THEN 3
        WHEN '白卡' THEN 4 WHEN '一般會員' THEN 5 ELSE 6
      END, total_amount DESC NULLS LAST, id DESC
    SQL

    super
  end
end

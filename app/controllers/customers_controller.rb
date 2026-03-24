# frozen_string_literal: true

class CustomersController < ApplicationController
  PER_PAGE = 50
  MAX_PAGE = 200

  AGE_GROUP_ORDER = ["未滿 25", "25–29", "30–34", "35–39", "40–44", "45 以上"].freeze

  ZODIAC_ORDER    = %w[牡羊 金牛 雙子 巨蟹 獅子 處女 天秤 天蠍 射手 摩羯 水瓶 雙魚].freeze

  def index
    @q                = params[:q].to_s.strip
    @city             = params[:city].to_s.strip
    @membership_level = params[:membership_level].to_s.strip
    @min_credits      = to_number(params[:min_credits])
    @sort             = params[:sort].to_s.strip.presence || "amount_desc"
    @zodiac           = params[:zodiac].to_s.strip
    @birth_month      = params[:birth_month].to_s.strip
    @age_group        = params[:age_group].to_s.strip
    @life_path        = params[:life_path].to_s.strip
    @personal_year    = params[:personal_year].to_s.strip
    @brand_ambassador = params[:brand_ambassador].to_s.strip
    @big_first_filter = params[:big_first].to_s.strip

    @membership_levels = ShoplineCustomer.distinct.pluck(:membership_level).compact.sort

    @page = params[:page].to_i
    @page = 1 if @page <= 0
    @page = MAX_PAGE if @page > MAX_PAGE

    @city_by_membership = ShoplineCustomer
      .where.not(membership_level: [nil, ""])
      .where.not(city: [nil, ""])
      .group(:membership_level, :city)
      .count
      .each_with_object(Hash.new { |h, k| h[k] = {} }) do |((level, city), cnt), h|
        h[level][city] = cnt
      end

    @membership_order = %w[黑卡 金卡 銀卡 白卡 一般會員]

    scope = ShoplineCustomer.includes(:customer_profile).all

    if @q.present?
      like = "%#{@q}%"
      scope = scope.where(
        "full_name ILIKE :like OR email ILIKE :like OR mobile_phone ILIKE :like OR phone ILIKE :like OR instagram_account ILIKE :like",
        like: like
      )
    end

    scope = scope.where("city ILIKE ?", "%#{@city}%")                           if @city.present?
    scope = scope.where(membership_level: @membership_level)                    if @membership_level.present?
    scope = scope.where("current_shopping_credits >= ?", @min_credits)          if @min_credits
    scope = scope.where("EXTRACT(MONTH FROM birthdate) = ?", @birth_month.to_i) if @birth_month.present?
    scope = scope.where(age_group_sql(@age_group))                              if @age_group.present?
    scope = scope.where(zodiac_sql(@zodiac))                                    if @zodiac.present?

    if @life_path.present?
      lp_num = @life_path.to_i
      matching_ids = ShoplineCustomer
        .where.not(birthdate: nil)
        .pluck(:id, :birthdate)
        .select { |_, bd| life_path_number(bd) == lp_num }
        .map(&:first)
      scope = scope.where(id: matching_ids)
    end

    if @personal_year.present?
      py_num = @personal_year.to_i
      matching_ids = ShoplineCustomer
        .where.not(birthdate: nil)
        .pluck(:id, :birthdate)
        .select { |_, bd| personal_year_number(bd) == py_num }
        .map(&:first)
      scope = scope.where(id: matching_ids)
    end

    scope = scope.where.not(email: [nil, ""]).or(scope.where.not(mobile_phone: [nil, ""]))

    if @brand_ambassador == "1"
      scope = scope.joins(:customer_profile).where(customer_profiles: { brand_ambassador_training: true })
    end

    if @big_first_filter == "1"
      scope = scope.joins(
        "INNER JOIN (
          SELECT DISTINCT ON (email) email, total_amount AS first_amount
          FROM shopline_orders
          ORDER BY email, order_date ASC
        ) fo ON fo.email = shopline_customers.email"
      ).where("fo.first_amount >= 10000")
    end

    if @sort.start_with?("inactive")
      scope = scope
        .joins("LEFT JOIN (
          SELECT email, MAX(order_date) AS last_order_date
          FROM shopline_orders
          WHERE product_name IS NOT NULL AND product_name != ''
          GROUP BY email
        ) lo ON lo.email = shopline_customers.email")
        .select("shopline_customers.*")
        .select("lo.last_order_date")
    else
      scope = scope.select("shopline_customers.*")
    end

    scope = scope.reorder(Arel.sql(order_sql(@sort)))

    @total = if @sort.start_with?("inactive")
      ShoplineCustomer.from(scope.except(:select, :order), :shopline_customers).count
    else
      scope.count
    end

    @total_pages = (@total.to_f / PER_PAGE).ceil
    @total_pages = 1 if @total_pages <= 0
    offset = (@page - 1) * PER_PAGE
    @customers = scope.offset(offset).limit(PER_PAGE)

    emails = @customers.map(&:email).compact.uniq

    orders_by_email = ShoplineOrder
      .where(email: emails)
      .where.not(product_name: [nil, ""])
      .select(:email, :product_name, :quantity)
      .group_by(&:email)

    @top_products = {}
    orders_by_email.each do |email, orders|
      series_counts = Hash.new { |h, k| h[k] = { qty: 0, count: 0 } }
      orders.each do |o|
        series, bottles_per_unit = parse_product(o.product_name)
        series_counts[series][:qty]   += o.quantity.to_i * bottles_per_unit
        series_counts[series][:count] += 1
      end
      @top_products[email] = series_counts.max_by { |_, v| [v[:qty], v[:count]] }&.first
    end

    last_order_by_email = ShoplineOrder
      .where(email: emails)
      .where.not(product_name: [nil, ""])
      .select(:email, :product_name, :order_date)
      .group_by(&:email)
      .transform_values { |orders| orders.max_by(&:order_date) }

    @inactive_info = {}
    last_order_by_email.each do |email, last_order|
      next unless last_order.order_date
      days_ago = (Date.today - last_order.order_date.to_date).to_i
      if days_ago >= 60
        series, _ = parse_product(last_order.product_name)
        @inactive_info[email] = { days: days_ago, last_product: series }
      end
    end

    first_orders_by_email = ShoplineOrder
      .where(email: emails)
      .select("DISTINCT ON (email) email, order_date, total_amount")
      .order("email, order_date ASC")
      .index_by(&:email)

    @big_first_orders = {}
    first_orders_by_email.each do |email, order|
      if order.total_amount.to_f >= 10_000
        @big_first_orders[email] = order.order_date
      end
    end
  end

  def show
    @customer = ShoplineCustomer.find(params[:id])
    @profile  = @customer.customer_profile || @customer.build_customer_profile
    @orders   = ShoplineOrder.where(email: @customer.email).order(order_date: :desc)
    @product_analysis = analyze_products(@orders)
    @life_path = @customer.birthdate.present? ? life_path_number(@customer.birthdate) : nil
    @personal_year = @customer.birthdate.present? ? personal_year_number(@customer.birthdate) : nil
    @zodiac_sign = @customer.birthdate.present? ? zodiac_sign(@customer.birthdate) : nil
  end

  def stats
    @membership_order = %w[黑卡 金卡 銀卡 白卡 一般會員]

    customers = ShoplineCustomer
      .where.not(membership_level: [nil, ""])
      .select(:membership_level, :city, :birthdate)

    @total_by_level    = Hash.new(0)
    @city_stats        = Hash.new { |h, k| h[k] = Hash.new(0) }
    @birth_month_stats = Hash.new { |h, k| h[k] = Hash.new(0) }
    @life_path_stats   = Hash.new { |h, k| h[k] = Hash.new(0) }
    @age_group_stats   = Hash.new { |h, k| h[k] = Hash.new(0) }
    @zodiac_stats      = Hash.new { |h, k| h[k] = Hash.new(0) }
    @personal_year_stats = Hash.new { |h, k| h[k] = Hash.new(0) }

    customers.each do |c|
      lvl = c.membership_level
      @total_by_level[lvl] += 1
      @city_stats[lvl][c.city] += 1 if c.city.present?

      next unless c.birthdate.present?

      @birth_month_stats[lvl][c.birthdate.month] += 1
      @age_group_stats[lvl][age_group(c.birthdate)] += 1
      @zodiac_stats[lvl][zodiac_sign(c.birthdate)] += 1

      lp = life_path_number(c.birthdate)
      @life_path_stats[lvl][lp] += 1 if lp

      py = personal_year_number(c.birthdate)
      @personal_year_stats[lvl][py] += 1 if py
    end
  end

  def edit
    @customer = ShoplineCustomer.find(params[:id])
    @profile  = @customer.customer_profile || @customer.build_customer_profile
  end

  def update
    @customer = ShoplineCustomer.find(params[:id])
    @profile  = @customer.customer_profile || @customer.build_customer_profile
    if @profile.update(profile_params)
      redirect_to customer_path(@customer), notice: "已儲存"
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def profile_params
    params.require(:customer_profile).permit(:brand_ambassador_training, :notes)
  end

  def age_group_sql(group)
  case group
    when "未滿 25" then "EXTRACT(YEAR FROM AGE(birthdate)) < 25"
    when "25–29"   then "EXTRACT(YEAR FROM AGE(birthdate)) BETWEEN 25 AND 29"
    when "30–34"   then "EXTRACT(YEAR FROM AGE(birthdate)) BETWEEN 30 AND 34"
    when "35–39"   then "EXTRACT(YEAR FROM AGE(birthdate)) BETWEEN 35 AND 39"
    when "40–44"   then "EXTRACT(YEAR FROM AGE(birthdate)) BETWEEN 40 AND 44"
    when "45 以上"  then "EXTRACT(YEAR FROM AGE(birthdate)) >= 45"
    end
  end

  def zodiac_sql(sign)
    {
      "牡羊" => "(EXTRACT(MONTH FROM birthdate)=3  AND EXTRACT(DAY FROM birthdate)>=21) OR (EXTRACT(MONTH FROM birthdate)=4  AND EXTRACT(DAY FROM birthdate)<=19)",
      "金牛" => "(EXTRACT(MONTH FROM birthdate)=4  AND EXTRACT(DAY FROM birthdate)>=20) OR (EXTRACT(MONTH FROM birthdate)=5  AND EXTRACT(DAY FROM birthdate)<=20)",
      "雙子" => "(EXTRACT(MONTH FROM birthdate)=5  AND EXTRACT(DAY FROM birthdate)>=21) OR (EXTRACT(MONTH FROM birthdate)=6  AND EXTRACT(DAY FROM birthdate)<=20)",
      "巨蟹" => "(EXTRACT(MONTH FROM birthdate)=6  AND EXTRACT(DAY FROM birthdate)>=21) OR (EXTRACT(MONTH FROM birthdate)=7  AND EXTRACT(DAY FROM birthdate)<=22)",
      "獅子" => "(EXTRACT(MONTH FROM birthdate)=7  AND EXTRACT(DAY FROM birthdate)>=23) OR (EXTRACT(MONTH FROM birthdate)=8  AND EXTRACT(DAY FROM birthdate)<=22)",
      "處女" => "(EXTRACT(MONTH FROM birthdate)=8  AND EXTRACT(DAY FROM birthdate)>=23) OR (EXTRACT(MONTH FROM birthdate)=9  AND EXTRACT(DAY FROM birthdate)<=22)",
      "天秤" => "(EXTRACT(MONTH FROM birthdate)=9  AND EXTRACT(DAY FROM birthdate)>=23) OR (EXTRACT(MONTH FROM birthdate)=10 AND EXTRACT(DAY FROM birthdate)<=22)",
      "天蠍" => "(EXTRACT(MONTH FROM birthdate)=10 AND EXTRACT(DAY FROM birthdate)>=23) OR (EXTRACT(MONTH FROM birthdate)=11 AND EXTRACT(DAY FROM birthdate)<=21)",
      "射手" => "(EXTRACT(MONTH FROM birthdate)=11 AND EXTRACT(DAY FROM birthdate)>=22) OR (EXTRACT(MONTH FROM birthdate)=12 AND EXTRACT(DAY FROM birthdate)<=21)",
      "摩羯" => "(EXTRACT(MONTH FROM birthdate)=12 AND EXTRACT(DAY FROM birthdate)>=22) OR (EXTRACT(MONTH FROM birthdate)=1  AND EXTRACT(DAY FROM birthdate)<=19)",
      "水瓶" => "(EXTRACT(MONTH FROM birthdate)=1  AND EXTRACT(DAY FROM birthdate)>=20) OR (EXTRACT(MONTH FROM birthdate)=2  AND EXTRACT(DAY FROM birthdate)<=18)",
      "雙魚" => "(EXTRACT(MONTH FROM birthdate)=2  AND EXTRACT(DAY FROM birthdate)>=19) OR (EXTRACT(MONTH FROM birthdate)=3  AND EXTRACT(DAY FROM birthdate)<=20)",
    }[sign]
  end

  AGE_GROUP_ORDER = ["未滿 25", "25–29", "30–34", "35–39", "40–44", "45 以上"].freeze

  def age_group(birthdate)
    age = ((Date.today - birthdate.to_date) / 365.25).floor
    case age
    when 0..24  then "未滿 25"
    when 25..29 then "25–29"
    when 30..34 then "30–34"
    when 35..39 then "35–39"
    when 40..44 then "40–44"
    else             "45 以上"
    end
  end

  def zodiac_sign(date)
    m, d = date.month, date.day
    case
    when (m == 3  && d >= 21) || (m == 4  && d <= 19) then "牡羊"
    when (m == 4  && d >= 20) || (m == 5  && d <= 20) then "金牛"
    when (m == 5  && d >= 21) || (m == 6  && d <= 20) then "雙子"
    when (m == 6  && d >= 21) || (m == 7  && d <= 22) then "巨蟹"
    when (m == 7  && d >= 23) || (m == 8  && d <= 22) then "獅子"
    when (m == 8  && d >= 23) || (m == 9  && d <= 22) then "處女"
    when (m == 9  && d >= 23) || (m == 10 && d <= 22) then "天秤"
    when (m == 10 && d >= 23) || (m == 11 && d <= 21) then "天蠍"
    when (m == 11 && d >= 22) || (m == 12 && d <= 21) then "射手"
    when (m == 12 && d >= 22) || (m == 1  && d <= 19) then "摩羯"
    when (m == 1  && d >= 20) || (m == 2  && d <= 18) then "水瓶"
    else "雙魚"
    end
  end

  def life_path_number(date)
    sum = date.strftime("%Y%m%d").chars.map(&:to_i).sum
    loop do
      break if sum <= 9
      sum = sum.to_s.chars.map(&:to_i).sum
    end
    sum
  end

  def personal_year_number(birthdate)
    year_sum = Date.today.year.digits.sum
    month_sum = birthdate.month.digits.sum
    day_sum = birthdate.day.digits.sum
    sum = year_sum + month_sum + day_sum
    loop do
      break if sum <= 9
      sum = sum.to_s.chars.map(&:to_i).sum
    end
    sum
  end

  def analyze_products(orders)
    today = Date.today
    series_grouped = Hash.new { |h, k| h[k] = [] }

    orders.where.not(product_name: [nil, ""]).each do |order|
      series, bottles_per_unit = parse_product(order.product_name)
      series_grouped[series] << {
        order: order,
        bottles_per_unit: bottles_per_unit,
        bottles_total: (order.quantity.to_i * bottles_per_unit)
      }
    end

    series_grouped.map do |series_name, items|
      items_sorted = items.sort_by { |i| i[:order].order_date || Date.new(0) }
      dates = items_sorted.map { |i| i[:order].order_date&.to_date }.compact.uniq.sort

      total_qty_bottles     = items.sum { |i| i[:bottles_total] }
      total_amount          = items.sum { |i| i[:order].total_amount.to_f }
      order_count           = items.map { |i| i[:order].order_number }.uniq.size
      last_purchase_bottles = items_sorted.last&.fetch(:bottles_total) || 0

      avg_cycle_days = if dates.size >= 2
        intervals = dates.each_cons(2).map { |a, b| (b - a).to_i }.reject { |i| i <= 0 }
        intervals.any? ? (intervals.sum.to_f / intervals.size).round : nil
      end

      avg_bottles_per_purchase = order_count > 0 ? (total_qty_bottles.to_f / order_count).round(1) : nil

      days_per_bottle = if avg_cycle_days && avg_bottles_per_purchase && avg_bottles_per_purchase > 0
        (avg_cycle_days.to_f / avg_bottles_per_purchase).round(1)
      end

      days_since_last = dates.last ? (today - dates.last).to_i : nil

      estimated_stock = if days_per_bottle && days_since_last && last_purchase_bottles > 0
        (last_purchase_bottles - (days_since_last.to_f / days_per_bottle)).round(1)
      end

      estimated_empty_date = if days_per_bottle && dates.last && last_purchase_bottles > 0
        dates.last + (last_purchase_bottles * days_per_bottle).round
      end

      overdue_days = if estimated_empty_date && today > estimated_empty_date
        (today - estimated_empty_date).to_i
      end

      {
        product_name:             series_name,
        order_count:              order_count,
        total_qty_bottles:        total_qty_bottles,
        total_amount:             total_amount,
        first_date:               dates.first,
        last_date:                dates.last,
        last_purchase_bottles:    last_purchase_bottles,
        avg_bottles_per_purchase: avg_bottles_per_purchase,
        avg_cycle_days:           avg_cycle_days,
        days_per_bottle:          days_per_bottle,
        days_since_last:          days_since_last,
        estimated_stock:          estimated_stock,
        estimated_empty_date:     estimated_empty_date,
        overdue_days:             overdue_days,
        dates:                    dates
      }
    end.sort_by { |p| [-p[:total_qty_bottles], -p[:order_count], p[:avg_cycle_days] || Float::INFINITY] }
  end

  def parse_product(name)
    if name =~ /^(.+?)(\d+)$/
      [$1.strip, $2.to_i]
    else
      [name, 1]
    end
  end

  def to_number(v)
    s = v.to_s.strip
    return nil if s.blank?
    s = s.gsub(/[,\uFF0C]/, "")
    Float(s)
  rescue ArgumentError
    nil
  end

  def order_sql(sort)
    case sort
    when "amount_desc"   then "total_amount DESC NULLS LAST, id DESC"
    when "amount_asc"    then "total_amount ASC NULLS LAST, id DESC"
    when "orders_desc"   then "order_count DESC NULLS LAST, id DESC"
    when "orders_asc"    then "order_count ASC NULLS LAST, id DESC"
    when "credits_desc"  then "current_shopping_credits DESC NULLS LAST, id DESC"
    when "credits_asc"   then "current_shopping_credits ASC NULLS LAST, id DESC"
    when "inactive_desc" then "lo.last_order_date ASC NULLS LAST, id DESC"
    when "inactive_asc"  then "lo.last_order_date DESC NULLS LAST, id DESC"
    when "newest"        then "created_at DESC, id DESC"
    else "total_amount DESC NULLS LAST, id DESC"
    end
  end
end